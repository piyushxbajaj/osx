/*
 * Copyright (c) 2017 Apple Inc. All Rights Reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */

#import "SFSQLite.h"
#import "SFSQLiteStatement.h"
#include <sqlite3.h>
#include <CommonCrypto/CommonDigest.h>


#define kSFSQLiteBusyTimeout       (5*60*1000)

// Vaccuum our databases approximately once a week
#define kCKSQLVacuumInterval       ((60*60*24)*7)
#define kSFSQLiteLastVacuumKey     @"LastVacuum"

#define kSFSQLiteSchemaVersionKey  @"SchemaVersion"
#define kSFSQLiteCreatedDateKey    @"Created"

static NSString *const kSFSQLiteCreatePropertiesTableSQL =
    @"create table if not exists Properties (\n"
    @"    key    text primary key,\n"
    @"    value  text\n"
    @");\n";

@interface SFSQLiteError : NSObject
+ (void)raise:(NSString *)reason code:(int)code extended:(int)extended;
@end


NSArray *SFSQLiteJournalSuffixes() {
    return @[@"-journal", @"-wal", @"-shm"];
}

@interface NSObject (SFSQLiteAdditions)
+ (NSString *)SFSQLiteClassName;
@end

@implementation NSObject (SFSQLiteAdditions)
+ (NSString *)SFSQLiteClassName {
    return NSStringFromClass(self);
}
@end

@interface SFSQLite ()

@property (nonatomic, assign)            sqlite3                *db;
@property (nonatomic, assign)            NSUInteger              openCount;
@property (nonatomic, assign)            BOOL                    corrupt;
@property (nonatomic, readonly, strong)  NSMutableDictionary    *statementsBySQL;
@property (nonatomic, strong)            NSDateFormatter        *dateFormatter;

@end

static char intToHexChar(uint8_t i)
{
    return i >= 10 ? 'a' + i - 10 : '0' + i;
}

static char *SecHexCharFromBytes(const uint8_t *bytes, NSUInteger length, NSUInteger *outlen) {
    // Fudge the math a bit on the assert because we don't want a 1GB string anyway
    if (length > (NSUIntegerMax / 3)) {
        return nil;
    }
    char *hex = calloc(1, length * 2 * 9 / 8); // 9/8 so we can inline ' ' between every 8 character sequence
    char *destPtr = hex;

    NSUInteger i;

    for (i = 0; length > 4; i += 4, length -= 4) {
        for (NSUInteger offset = 0; offset < 4; offset++) {
            *destPtr++ = intToHexChar((bytes[i+offset] & 0xF0) >> 4);
            *destPtr++ = intToHexChar(bytes[i+offset] & 0x0F);
        }
        *destPtr++ = ' ';
    }

    /* Using the same i from the above loop */
    for (; length > 0; i++, length--) {
        *destPtr++ = intToHexChar((bytes[i] & 0xF0) >> 4);
        *destPtr++ = intToHexChar(bytes[i] & 0x0F);
    }

    if (outlen) *outlen = destPtr - hex;

    return hex;
}

static BOOL SecCreateDirectoryAtPath(NSString *path, NSError **error) {
    BOOL success = YES;
    NSError *localError;
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if (![fileManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&localError]) {
        if (![localError.domain isEqualToString:NSCocoaErrorDomain] || localError.code != NSFileWriteFileExistsError) {
            success = NO;
        }
    }

#if TARGET_OS_IPHONE
    if (success) {
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:&localError];
        if (![attributes[NSFileProtectionKey] isEqualToString:NSFileProtectionCompleteUntilFirstUserAuthentication]) {
            [fileManager setAttributes:@{ NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication }
                          ofItemAtPath:path error:nil];
        }
    }
#endif
    if (!success) {
        if (error) *error = localError;
    }
    return success;
}

@implementation NSData (CKUtilsAdditions)

- (NSString *)CKHexString {
    NSUInteger hexLen = 0;
    NS_VALID_UNTIL_END_OF_SCOPE NSData *arcSafeSelf = self;
    char *hex = SecHexCharFromBytes([arcSafeSelf bytes], [arcSafeSelf length], &hexLen);
    return [[NSString alloc] initWithBytesNoCopy:hex length:hexLen encoding:NSASCIIStringEncoding freeWhenDone:YES];
}

- (NSString *)CKLowercaseHexStringWithoutSpaces {
    NSMutableString *retVal = [[self CKHexString] mutableCopy];
    [retVal replaceOccurrencesOfString:@" " withString:@"" options:0 range:NSMakeRange(0, [retVal length])];
    return retVal;
}

- (NSString *)CKUppercaseHexStringWithoutSpaces {
    NSMutableString *retVal = [[[self CKHexString] uppercaseString] mutableCopy];
    [retVal replaceOccurrencesOfString:@" " withString:@"" options:0 range:NSMakeRange(0, [retVal length])];
    return retVal;
}

+ (NSData *)CKDataWithHexString:(NSString *)hexString stringIsUppercase:(BOOL)stringIsUppercase {
    NSMutableData *retVal = [[NSMutableData alloc] init];
    NSCharacterSet *hexCharacterSet = nil;
    char aChar;
    if (stringIsUppercase) {
        hexCharacterSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"];
        aChar = 'A';
    } else {
        hexCharacterSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
        aChar = 'a';
    }

    unsigned int i;
    for (i = 0; i < [hexString length] ; ) {
        BOOL validFirstByte = NO;
        BOOL validSecondByte = NO;
        unichar firstByte = 0;
        unichar secondByte = 0;

        for ( ; i < [hexString length]; i++) {
            firstByte = [hexString characterAtIndex:i];
            if ([hexCharacterSet characterIsMember:firstByte]) {
                i++;
                validFirstByte = YES;
                break;
            }
        }
        for ( ; i < [hexString length]; i++) {
            secondByte = [hexString characterAtIndex:i];
            if ([hexCharacterSet characterIsMember:secondByte]) {
                i++;
                validSecondByte = YES;
                break;
            }
        }
        if (!validFirstByte || !validSecondByte) {
            goto allDone;
        }
        if ((firstByte >= '0') && (firstByte <= '9')) {
            firstByte -= '0';
        } else {
            firstByte = firstByte - aChar + 10;
        }
        if ((secondByte >= '0') && (secondByte <= '9')) {
            secondByte -= '0';
        } else {
            secondByte = secondByte - aChar + 10;
        }
        char totalByteValue = (char)((firstByte << 4) + secondByte);

        [retVal appendBytes:&totalByteValue length:1];
    }
allDone:
    return retVal;
}

+ (NSData *)CKDataWithHexString:(NSString *)hexString {
    return [self CKDataWithHexString:hexString stringIsUppercase:NO];
}

@end

@implementation SFSQLite

@synthesize delegate = _delegate;
@synthesize path = _path;
@synthesize schema = _schema;
@synthesize schemaVersion = _schemaVersion;
@synthesize objectClassPrefix = _objectClassPrefix;
@synthesize userVersion = _userVersion;
@synthesize synchronousMode = _synchronousMode;
@synthesize hasMigrated = _hasMigrated;
@synthesize shouldVacuum = _shouldVacuum;
@synthesize traced = _traced;
@synthesize db = _db;
@synthesize openCount = _openCount;
@synthesize corrupt = _corrupt;
@synthesize statementsBySQL = _statementsBySQL;
@synthesize dateFormatter = _dateFormatter;
#if DEBUG
@synthesize unitTestOverrides = _unitTestOverrides;
#endif

- (instancetype)initWithPath:(NSString *)path schema:(NSString *)schema {
    if ((self = [super init])) {
        NSAssert([path length], @"Can't init a database with a zero-length path");
        _path = path;
        _schema = schema;
        _schemaVersion = [self _createSchemaHash];
        _statementsBySQL = [[NSMutableDictionary alloc] init];
        _objectClassPrefix = @"CK";
        _synchronousMode = SFSQLiteSynchronousModeNormal;
        _hasMigrated = NO;
        _shouldVacuum = YES;
    }
    return self;
}

- (void)dealloc {
    @autoreleasepool {
        [self close];
    }
}

- (SInt32)userVersion {
    if (self.delegate) {
        return self.delegate.userVersion;
    }
    return _userVersion;
}

- (NSString *)_synchronousModeString {
    switch (self.synchronousMode) {
        case SFSQLiteSynchronousModeOff:
            return @"off";
        case SFSQLiteSynchronousModeFull:
            return @"full";
        case SFSQLiteSynchronousModeNormal:
            break;
        default:
            assert(0 && "Unknown synchronous mode");
    }
    return @"normal";
}

- (NSString *)_createSchemaHash {
    unsigned char hashBuffer[CC_SHA256_DIGEST_LENGTH] = {0};
    NSData *hashData = [NSData dataWithBytesNoCopy:hashBuffer length:CC_SHA256_DIGEST_LENGTH freeWhenDone:NO];
    NS_VALID_UNTIL_END_OF_SCOPE NSData *schemaData = [self.schema dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA256([schemaData bytes], (CC_LONG)[schemaData length], hashBuffer);
    return [hashData CKUppercaseHexStringWithoutSpaces];
}

- (BOOL)isOpen {
    return _db != NULL;
}

- (void)_periodicVacuum {
    // "When the auto-vacuum mode is 1 or "full", the freelist pages are moved to the end of the database file and the database file is truncated to remove the freelist pages at every transaction commit.
    // Note, however, that auto-vacuum only truncates the freelist pages from the file. Auto-vacuum does not defragment the database nor repack individual database pages the way that the VACUUM command does.
    // In fact, because it moves pages around within the file, auto-vacuum can actually make fragmentation worse."
    // https://sqlite.org/pragma.html#pragma_auto_vacuum
    NSDate *lastVacuumDate = [NSDate dateWithTimeIntervalSinceReferenceDate:[[self propertyForKey:kSFSQLiteLastVacuumKey] floatValue]];
    if ([lastVacuumDate timeIntervalSinceNow] < -(kCKSQLVacuumInterval)) {
        [self executeSQL:@"VACUUM"];

        NSString *vacuumDateString = [NSString stringWithFormat:@"%f", [[NSDate date] timeIntervalSinceReferenceDate]];
        [self setProperty:vacuumDateString forKey:kSFSQLiteLastVacuumKey];
    }
}

- (BOOL)openWithError:(NSError **)error {
    BOOL success = NO;
    NSError *localError;
    NSString *dbSchemaVersion, *dir;
    NSArray *results;
    NS_VALID_UNTIL_END_OF_SCOPE NSString *arcSafePath = _path;
    
    if (_openCount > 0) {
        NSAssert(_db != NULL, @"Missing handle for open cache db");
        _openCount += 1;
        success = YES;
        goto done;
    }
    
    // Create the directory for the cache.
    dir = [_path stringByDeletingLastPathComponent];
    if (!SecCreateDirectoryAtPath(dir, &localError)) {
        goto done;
    }

    int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
#if TARGET_OS_IPHONE
    flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION;
#endif
    int rc = sqlite3_open_v2([arcSafePath fileSystemRepresentation], &_db, flags, NULL);
    if (rc != SQLITE_OK) {
        localError = [NSError errorWithDomain:NSCocoaErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Error opening db at %@, rc=%d(0x%x)", _path, rc, rc]}];
        goto done;
    }
    sqlite3_extended_result_codes(_db, 1);
    rc = sqlite3_busy_timeout(_db, kSFSQLiteBusyTimeout);
    if (rc != SQLITE_OK) {
        goto done;
    }
    
    // You don't argue with the Ben: rdar://12685305
    [self executeSQL:@"pragma journal_mode = WAL"];
    [self executeSQL:@"pragma synchronous = %@", [self _synchronousModeString]];
    [self executeSQL:@"pragma auto_vacuum = FULL"];
    
    // rdar://problem/32168789
    // [self executeSQL:@"pragma foreign_keys = 1"];
    
    // Initialize the db within a transaction in case there is a crash between creating the schema and setting the
    // schema version, and to avoid multiple threads trying to re-create the db at once.
    [self begin];

    // Create the Properties table before trying to read the schema version from it. If the Properties table doesn't
    // exist we can't prepare a statement to access it.
    results = [self select:@[@"name"] from:@"sqlite_master" where:@"type = ? AND name = ?" bindings:@[@"table", @"Properties"]];
    if (!results.count) {
        [self executeSQL:kSFSQLiteCreatePropertiesTableSQL];
    }
    
    // Check the schema version and create or re-create the db if needed.
    BOOL create = NO;
    dbSchemaVersion = [self propertyForKey:kSFSQLiteSchemaVersionKey];
    SInt32 dbUserVersion = [self dbUserVersion];
    
    if (!dbSchemaVersion) {
        // The schema version isn't set so the db was just created or we failed to initialize it previously.
        create = YES;
    } else if (![dbSchemaVersion isEqualToString:self.schemaVersion]
               || (self.userVersion && dbUserVersion != self.userVersion)) {

        if (self.delegate && [self.delegate migrateDatabase:self fromVersion:dbUserVersion]) {
            _hasMigrated = YES;
        }

        if (!_hasMigrated) {
            // The schema version doesn't match and we haven't migrated to the new version. Give up and throw away the db and re-create it instead of trying to migrate.
            [self removeAllStatements];
            [self dropAllTables];
            create = YES;
            _hasMigrated = YES;
        }
    }
    if (create) {
        [self executeSQL:kSFSQLiteCreatePropertiesTableSQL];
        [self executeSQL:@"%@", self.schema];
        NSString *createdDateString = [NSString stringWithFormat:@"%f", [[NSDate date] timeIntervalSinceReferenceDate]];
        [self setProperty:createdDateString forKey:kSFSQLiteCreatedDateKey];
    }
    
    [self end];
    
#if DEBUG
    // TODO: <rdar://problem/33115830> Resolve Race Condition When Setting 'userVersion/schemaVersion' in SFSQLite
    if ([self.unitTestOverrides[@"RacyUserVersionUpdate"] isEqual:@YES]) {
        success = YES;
        goto done;
    }
#endif
    
    if (self.shouldVacuum) [self _periodicVacuum];

    if (create || _hasMigrated) {
        [self setProperty:self.schemaVersion forKey:kSFSQLiteSchemaVersionKey];
        if (self.userVersion) {
            [self executeSQL:@"pragma user_version = %ld", (long)self.userVersion];
        }
    }

    _openCount += 1;
    success = YES;
    
done:
    if (!success && error) {
        *error = localError;
    }
    return success;
}

- (void)open {
    NSError *error;
    if (![self openWithError:&error]) {
        [self raise:@"Error opening db at %@: %@", self.path, error];
    }
}


- (void)close {
    if (_openCount > 0) {
        if (_openCount == 1) {
            NSAssert(_db != NULL, @"Missing handle for open cache db");
            
            [self removeAllStatements];
            
            if (sqlite3_close(_db)) {
                [self raise:@"Error closing database"];
            }
            _db = NULL;
        }
        _openCount -= 1;
    }
}

- (void)remove {
    NSAssert(_openCount == 0, @"Trying to remove db at: %@ while it is open", _path);
    [[NSFileManager defaultManager] removeItemAtPath:_path error:nil];
    for (NSString *suffix in SFSQLiteJournalSuffixes()) {
        [[NSFileManager defaultManager] removeItemAtPath:[_path stringByAppendingString:suffix] error:nil];
    }
}

- (void)begin {
    [self executeSQL:@"begin exclusive"];
}

- (void)end {
    [self executeSQL:@"end"];
}

- (void)rollback {
    [self executeSQL:@"rollback"];
}

- (void)analyze {
    [self executeSQL:@"analyze"];
}

- (void)vacuum {
    [self executeSQL:@"vacuum"];
}

- (void)raise:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    
    NSString *reason = [[NSString alloc] initWithFormat:format arguments:args];
    
    int code = 0;
    int extendedCode = 0;
    if (_db) {
        code = sqlite3_errcode(_db) & 0xFF;
        extendedCode = sqlite3_extended_errcode(_db);
        const char *errmsg = sqlite3_errmsg(_db);

        NSDictionary *dbAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:self.path error:NULL];
        NSDictionary *fsAttrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:self.path error:NULL];
        reason = [reason stringByAppendingFormat:@" - errcode:%04x, msg:\"%s\", size: %@, path:%@, fs:%@/%@", extendedCode, errmsg, dbAttrs[NSFileSize], _path, fsAttrs[NSFileSystemFreeSize], fsAttrs[NSFileSystemSize]];

        if (!_corrupt && (code == SQLITE_CORRUPT || code == SQLITE_NOTADB)) {
            _corrupt = YES;
            
            @try {
                [self close];
            } @catch (NSException *x) {
                NSLog(@"Warn: Error closing corrupt db: %@", x);
            }
            
            [self remove];
        }
    }
    
    va_end(args);
    
    [SFSQLiteError raise:reason code:code extended:extendedCode];
}

- (SFSQLiteRowID)lastInsertRowID {
    if (!_db) {
        [self raise:@"Database is closed"];
    }
    
    return sqlite3_last_insert_rowid(_db);
}

- (int)changes
{
    if (!_db) {
        [self raise:@"Database is closed"];
    }
    
    return sqlite3_changes(_db);
}

- (void)executeSQL:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    [self executeSQL:format arguments:args];
    va_end(args);
}

- (void)executeSQL:(NSString *)format arguments:(va_list)args {
    NS_VALID_UNTIL_END_OF_SCOPE NSString *SQL = [[NSString alloc] initWithFormat:format arguments:args];
    if (!_db) {
        [self raise:@"Database is closed"];
    }
    int execRet = sqlite3_exec(_db, [SQL UTF8String], NULL, NULL, NULL);
    if (execRet != SQLITE_OK) {
        [self raise:@"Error executing SQL: \"%@\" (%d)", SQL, execRet];
    }
}

- (SFSQLiteStatement *)statementForSQL:(NSString *)SQL {
    if (!_db) {
        [self raise:@"Database is closed"];
    }
    
    SFSQLiteStatement *statement = _statementsBySQL[SQL];
    if (statement) {
        NSAssert(statement.isReset, @"Statement not reset after last use: \"%@\"", SQL);
    } else {
        sqlite3_stmt *handle = NULL;
        NS_VALID_UNTIL_END_OF_SCOPE NSString *arcSafeSQL = SQL;
        if (sqlite3_prepare_v2(_db, [arcSafeSQL UTF8String], -1, &handle, NULL)) {
            [self raise:@"Error preparing statement: %@", SQL];
        }
        
        statement = [[SFSQLiteStatement alloc] initWithSQLite:self SQL:SQL handle:handle];
        _statementsBySQL[SQL] = statement;
    }
    
    return statement;
}

- (void)removeAllStatements {
    [[_statementsBySQL allValues] makeObjectsPerformSelector:@selector(finalizeStatement)];
    [_statementsBySQL removeAllObjects];
}

- (NSArray *)allTableNames {
    NSMutableArray *tableNames = [[NSMutableArray alloc] init];
    
    SFSQLiteStatement *statement = [self statementForSQL:@"select name from sqlite_master where type = 'table'"];
    while ([statement step]) {
        NSString *name = [statement textAtIndex:0];
        [tableNames addObject:name];
    }
    [statement reset];
    
    return tableNames;
}

- (void)dropAllTables {
    for (NSString *tableName in [self allTableNames]) {
        [self executeSQL:@"drop table %@", tableName];
    }
}

- (NSString *)propertyForKey:(NSString *)key {
    NSAssert(key, @"Null key");
    
    NSString *value = nil;
    
    SFSQLiteStatement *statement = [self statementForSQL:@"select value from Properties where key = ?"];
    [statement bindText:key atIndex:0];
    if ([statement step]) {
        value = [statement textAtIndex:0];
    }
    [statement reset];
    
    return value;
}

- (void)setProperty:(NSString *)value forKey:(NSString *)key {
    NSAssert(key, @"Null key");
    
    if (value) {
        SFSQLiteStatement *statement = [self statementForSQL:@"insert or replace into Properties (key, value) values (?,?)"];
        [statement bindText:key atIndex:0];
        [statement bindText:value atIndex:1];
        [statement step];
        [statement reset];
    } else {
        [self removePropertyForKey:key];
    }
}

- (NSDateFormatter *)dateFormatter {
    if (!_dateFormatter) {
        NSDateFormatter* dateFormatter = [NSDateFormatter new];
        dateFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
        _dateFormatter = dateFormatter;
    }
    return _dateFormatter;
}

- (NSDate *)datePropertyForKey:(NSString *)key {
    NSString *dateStr = [self propertyForKey:key];
    if (dateStr.length) {
        return [self.dateFormatter dateFromString:dateStr];
    }
    return nil;
}

- (void)setDateProperty:(NSDate *)value forKey:(NSString *)key {
    NSString *dateStr = nil;
    if (value) {
        dateStr = [self.dateFormatter stringFromDate:value];
    }
    [self setProperty:dateStr forKey:key];
}

- (void)removePropertyForKey:(NSString *)key {
    NSAssert(key, @"Null key");
    
    SFSQLiteStatement *statement = [self statementForSQL:@"delete from Properties where key = ?"];
    [statement bindText:key atIndex:0];
    [statement step];
    [statement reset];
}

- (NSDate *)creationDate {
    return [NSDate dateWithTimeIntervalSinceReferenceDate:[[self propertyForKey:kSFSQLiteCreatedDateKey] floatValue]];
}

// https://sqlite.org/pragma.html#pragma_table_info
- (NSSet<NSString*> *)columnNamesForTable:(NSString*)tableName {
    SFSQLiteStatement *statement = [self statementForSQL:[NSString stringWithFormat:@"pragma table_info(%@)", tableName]];
    NSMutableSet<NSString*>* columnNames = [[NSMutableSet alloc] init];
    while ([statement step]) {
        [columnNames addObject:[statement textAtIndex:1]];
    }
    [statement reset];
    return columnNames;
}

- (NSArray *)select:(NSArray *)columns from:(NSString *)tableName {
    return [self select:columns from:tableName where:nil bindings:nil];
}

- (NSArray *)select:(NSArray *)columns from:(NSString *)tableName where:(NSString *)whereSQL bindings:(NSArray *)bindings {
    NSMutableArray *results = [[NSMutableArray alloc] init];
    
    NSMutableString *SQL = [NSMutableString stringWithFormat:@"select %@ from %@", [columns componentsJoinedByString:@", "], tableName];
    if (whereSQL) {
        [SQL appendFormat:@" where %@", whereSQL];
    }
    
    SFSQLiteStatement *statement = [self statementForSQL:SQL];
    [statement bindValues:bindings];
    while ([statement step]) {
        [results addObject:[statement allObjectsByColumnName]];
    }
    [statement reset];
    
    return results;
}

- (void)select:(NSArray *)columns from:(NSString *)tableName where:(NSString *)whereSQL bindings:(NSArray *)bindings orderBy:(NSArray *)orderBy limit:(NSNumber *)limit block:(void (^)(NSDictionary *resultDictionary, BOOL *stop))block {
    @autoreleasepool {
        NSMutableString *SQL = [[NSMutableString alloc] init];
        NSString *columnsString = @"*";
        if ([columns count]) columnsString = [columns componentsJoinedByString:@", "];
        [SQL appendFormat:@"select %@ from %@", columnsString, tableName];

        if (whereSQL.length) {
            [SQL appendFormat:@" where %@", whereSQL];
        }
        if (orderBy) {
            NSString *orderByString = [orderBy componentsJoinedByString:@", "];
            [SQL appendFormat:@" order by %@", orderByString];
        }
        if (limit) {
            [SQL appendFormat:@" limit %ld", (long)limit.integerValue];
        }

        SFSQLiteStatement *statement = [self statementForSQL:SQL];
        [statement bindValues:bindings];
        do {
            @autoreleasepool {
                if (![statement step]) {
                    break;
                }
                NSDictionary *stepResult = [statement allObjectsByColumnName];
                if (block) {
                    BOOL stop = NO;
                    block(stepResult, &stop);
                    if (stop) {
                        break;
                    }
                }
            }
        } while (1);
        [statement reset];
    }
}

- (void)selectFrom:(NSString *)tableName where:(NSString *)whereSQL bindings:(NSArray *)bindings orderBy:(NSArray *)orderBy limit:(NSNumber *)limit block:(void (^)(NSDictionary *resultDictionary, BOOL *stop))block {
    @autoreleasepool {
        NSMutableString *SQL = [[NSMutableString alloc] init];
        [SQL appendFormat:@"select * from %@", tableName];
        
        if (whereSQL.length) {
            [SQL appendFormat:@" where %@", whereSQL];
        }
        if (orderBy) {
            NSString *orderByString = [orderBy componentsJoinedByString:@", "];
            [SQL appendFormat:@" order by %@", orderByString];
        }
        if (limit) {
            [SQL appendFormat:@" limit %ld", (long)limit.integerValue];
        }
        
        SFSQLiteStatement *statement = [self statementForSQL:SQL];
        [statement bindValues:bindings];
        do {
            @autoreleasepool {
                if (![statement step]) {
                    break;
                }
                NSDictionary *stepResult = [statement allObjectsByColumnName];
                if (block) {
                    BOOL stop = NO;
                    block(stepResult, &stop);
                    if (stop) {
                        break;
                    }
                }
            }
        } while (1);
        [statement reset];
    }
}

- (NSArray *)selectFrom:(NSString *)tableName where:(NSString *)whereSQL bindings:(NSArray *)bindings limit:(NSNumber *)limit {
    NSMutableString *SQL = [[NSMutableString alloc] init];
    [SQL appendFormat:@"select * from %@", tableName];
    
    if (whereSQL.length) {
        [SQL appendFormat:@" where %@", whereSQL];
    }
    if (limit) {
        [SQL appendFormat:@" limit %ld", (long)limit.integerValue];
    }

    NSMutableArray *results = [[NSMutableArray alloc] init];

    SFSQLiteStatement *statement = [self statementForSQL:SQL];
    [statement bindValues:bindings];
    while ([statement step]) {
        [results addObject:[statement allObjectsByColumnName]];
    }
    [statement reset];
    
    return results;
}

- (void)update:(NSString *)tableName set:(NSString *)setSQL where:(NSString *)whereSQL bindings:(NSArray *)whereBindings limit:(NSNumber *)limit {
    NSMutableString *SQL = [[NSMutableString alloc] init];
    [SQL appendFormat:@"update %@", tableName];
    
    NSAssert(setSQL.length > 0, @"null set expression");

    [SQL appendFormat:@" set %@", setSQL];
    if (whereSQL.length) {
        [SQL appendFormat:@" where %@", whereSQL];
    }
    if (limit) {
        [SQL appendFormat:@" limit %ld", (long)limit.integerValue];
    }

    SFSQLiteStatement *statement = [self statementForSQL:SQL];
    [statement bindValues:whereBindings];
    while ([statement step]) {
    }
    [statement reset];
}

- (NSArray *)selectAllFrom:(NSString *)tableName where:(NSString *)whereSQL bindings:(NSArray *)bindings {
    return [self selectFrom:tableName where:whereSQL bindings:bindings limit:nil];
}

- (NSUInteger)selectCountFrom:(NSString *)tableName where:(NSString *)whereSQL bindings:(NSArray *)bindings {
    NSArray *results = [self select:@[@"count(*) as n"] from:tableName where:whereSQL bindings:bindings];
    return [results[0][@"n"] unsignedIntegerValue];
}

- (SFSQLiteRowID)insertOrReplaceInto:(NSString *)tableName values:(NSDictionary *)valuesByColumnName {
    NSArray *columnNames = [[valuesByColumnName allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *values = [[NSMutableArray alloc] init];
    for (NSUInteger i = 0; i < columnNames.count; i++) {
        values[i] = valuesByColumnName[columnNames[i]];
    }
    
    NSMutableString *SQL = [[NSMutableString alloc] initWithString:@"insert or replace into "];
    [SQL appendString:tableName];
    [SQL appendString:@" ("];
    for (NSUInteger i = 0; i < columnNames.count; i++) {
        [SQL appendString:columnNames[i]];
        if (i != columnNames.count-1) {
            [SQL appendString:@","];
        }
    }
    [SQL appendString:@") values ("];
    for (NSUInteger i = 0; i < columnNames.count; i++) {
        if (i != columnNames.count-1) {
            [SQL appendString:@"?,"];
        } else {
            [SQL appendString:@"?"];
        }
    }
    [SQL appendString:@")"];
    
    SFSQLiteStatement *statement = [self statementForSQL:SQL];
    [statement bindValues:values];
    [statement step];
    [statement reset];
    
    return [self lastInsertRowID];
}

- (void)deleteFrom:(NSString *)tableName matchingValues:(NSDictionary *)valuesByColumnName {
    NSArray *columnNames = [[valuesByColumnName allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *values = [[NSMutableArray alloc] init];
    NSMutableString *whereSQL = [[NSMutableString alloc] init];
    int bindingCount = 0;
    for (NSUInteger i = 0; i < columnNames.count; i++) {
        id value = valuesByColumnName[columnNames[i]];
        [whereSQL appendString:columnNames[i]];
        if (!value || [[NSNull null] isEqual:value]) {
            [whereSQL appendString:@" is NULL"];
        } else {
            values[bindingCount++] = value;
            [whereSQL appendString:@"=?"];
        }
        if (i != columnNames.count-1) {
            [whereSQL appendString:@" AND "];
        }
    }
    [self deleteFrom:tableName where:whereSQL bindings:values];
}

- (void)deleteFrom:(NSString *)tableName where:(NSString *)whereSQL bindings:(NSArray *)bindings {
    NSString *SQL = [NSString stringWithFormat:@"delete from %@ where %@", tableName, whereSQL];

    SFSQLiteStatement *statement = [self statementForSQL:SQL];
    [statement bindValues:bindings];
    [statement step];
    [statement reset];
}

- (NSString *)_tableNameForClass:(Class)objectClass {
    NSString *className = [objectClass SFSQLiteClassName];
    if (![className hasPrefix:_objectClassPrefix]) {
        [NSException raise:NSInvalidArgumentException format:@"Object class \"%@\" does not have prefix \"%@\"", className, _objectClassPrefix];
    }
    return [className substringFromIndex:_objectClassPrefix.length];
}

- (SInt32)dbUserVersion {
    SInt32 userVersion = 0;
    SFSQLiteStatement *statement = [self statementForSQL:@"pragma user_version"];
    while ([statement step]) {
        userVersion = [statement intAtIndex:0];
    }
    [statement reset];
    
    return userVersion;
}

@end


#define SFSQLiteErrorRaiseMethod(SQLiteError) + (void)SQLiteError:(NSString *)reason { [NSException raise:NSGenericException format:@"%@", reason]; }
#define SFSQLiteErrorCase(SQLiteError) case SQLITE_ ## SQLiteError: [self SQLiteError:reason]; break

@implementation SFSQLiteError

// SQLite error codes
SFSQLiteErrorRaiseMethod(ERROR)
SFSQLiteErrorRaiseMethod(INTERNAL)
SFSQLiteErrorRaiseMethod(PERM)
SFSQLiteErrorRaiseMethod(ABORT)
SFSQLiteErrorRaiseMethod(BUSY)
SFSQLiteErrorRaiseMethod(LOCKED)
SFSQLiteErrorRaiseMethod(NOMEM)
SFSQLiteErrorRaiseMethod(READONLY)
SFSQLiteErrorRaiseMethod(INTERRUPT)
SFSQLiteErrorRaiseMethod(IOERR)
SFSQLiteErrorRaiseMethod(CORRUPT)
SFSQLiteErrorRaiseMethod(NOTFOUND)
SFSQLiteErrorRaiseMethod(FULL)
SFSQLiteErrorRaiseMethod(CANTOPEN)
SFSQLiteErrorRaiseMethod(PROTOCOL)
SFSQLiteErrorRaiseMethod(SCHEMA)
SFSQLiteErrorRaiseMethod(TOOBIG)
SFSQLiteErrorRaiseMethod(CONSTRAINT)
SFSQLiteErrorRaiseMethod(MISMATCH)
SFSQLiteErrorRaiseMethod(MISUSE)
SFSQLiteErrorRaiseMethod(RANGE)
SFSQLiteErrorRaiseMethod(NOTADB)

// SQLite extended error codes
SFSQLiteErrorRaiseMethod(IOERR_READ)
SFSQLiteErrorRaiseMethod(IOERR_SHORT_READ)
SFSQLiteErrorRaiseMethod(IOERR_WRITE)
SFSQLiteErrorRaiseMethod(IOERR_FSYNC)
SFSQLiteErrorRaiseMethod(IOERR_DIR_FSYNC)
SFSQLiteErrorRaiseMethod(IOERR_TRUNCATE)
SFSQLiteErrorRaiseMethod(IOERR_FSTAT)
SFSQLiteErrorRaiseMethod(IOERR_UNLOCK)
SFSQLiteErrorRaiseMethod(IOERR_RDLOCK)
SFSQLiteErrorRaiseMethod(IOERR_DELETE)
SFSQLiteErrorRaiseMethod(IOERR_BLOCKED)
SFSQLiteErrorRaiseMethod(IOERR_NOMEM)
SFSQLiteErrorRaiseMethod(IOERR_ACCESS)
SFSQLiteErrorRaiseMethod(IOERR_CHECKRESERVEDLOCK)
SFSQLiteErrorRaiseMethod(IOERR_LOCK)
SFSQLiteErrorRaiseMethod(IOERR_CLOSE)
SFSQLiteErrorRaiseMethod(IOERR_DIR_CLOSE)
SFSQLiteErrorRaiseMethod(IOERR_SHMOPEN)
SFSQLiteErrorRaiseMethod(IOERR_SHMSIZE)
SFSQLiteErrorRaiseMethod(IOERR_SHMLOCK)
SFSQLiteErrorRaiseMethod(IOERR_SHMMAP)
SFSQLiteErrorRaiseMethod(IOERR_SEEK)
SFSQLiteErrorRaiseMethod(IOERR_DELETE_NOENT)
SFSQLiteErrorRaiseMethod(IOERR_MMAP)
SFSQLiteErrorRaiseMethod(IOERR_GETTEMPPATH)
SFSQLiteErrorRaiseMethod(IOERR_CONVPATH)
SFSQLiteErrorRaiseMethod(LOCKED_SHAREDCACHE)
SFSQLiteErrorRaiseMethod(BUSY_RECOVERY)
SFSQLiteErrorRaiseMethod(BUSY_SNAPSHOT)
SFSQLiteErrorRaiseMethod(CANTOPEN_NOTEMPDIR)
SFSQLiteErrorRaiseMethod(CANTOPEN_ISDIR)
SFSQLiteErrorRaiseMethod(CANTOPEN_FULLPATH)
SFSQLiteErrorRaiseMethod(CANTOPEN_CONVPATH)
SFSQLiteErrorRaiseMethod(CORRUPT_VTAB)
SFSQLiteErrorRaiseMethod(READONLY_RECOVERY)
SFSQLiteErrorRaiseMethod(READONLY_CANTLOCK)
SFSQLiteErrorRaiseMethod(READONLY_ROLLBACK)
SFSQLiteErrorRaiseMethod(READONLY_DBMOVED)
SFSQLiteErrorRaiseMethod(ABORT_ROLLBACK)
SFSQLiteErrorRaiseMethod(CONSTRAINT_CHECK)
SFSQLiteErrorRaiseMethod(CONSTRAINT_COMMITHOOK)
SFSQLiteErrorRaiseMethod(CONSTRAINT_FOREIGNKEY)
SFSQLiteErrorRaiseMethod(CONSTRAINT_FUNCTION)
SFSQLiteErrorRaiseMethod(CONSTRAINT_NOTNULL)
SFSQLiteErrorRaiseMethod(CONSTRAINT_PRIMARYKEY)
SFSQLiteErrorRaiseMethod(CONSTRAINT_TRIGGER)
SFSQLiteErrorRaiseMethod(CONSTRAINT_UNIQUE)
SFSQLiteErrorRaiseMethod(CONSTRAINT_VTAB)
SFSQLiteErrorRaiseMethod(CONSTRAINT_ROWID)
SFSQLiteErrorRaiseMethod(NOTICE_RECOVER_WAL)
SFSQLiteErrorRaiseMethod(NOTICE_RECOVER_ROLLBACK)

+ (void)raise:(NSString *)reason code:(int)code extended:(int)extended {
    switch(extended) {
            SFSQLiteErrorCase(IOERR_READ);
            SFSQLiteErrorCase(IOERR_SHORT_READ);
            SFSQLiteErrorCase(IOERR_WRITE);
            SFSQLiteErrorCase(IOERR_FSYNC);
            SFSQLiteErrorCase(IOERR_DIR_FSYNC);
            SFSQLiteErrorCase(IOERR_TRUNCATE);
            SFSQLiteErrorCase(IOERR_FSTAT);
            SFSQLiteErrorCase(IOERR_UNLOCK);
            SFSQLiteErrorCase(IOERR_RDLOCK);
            SFSQLiteErrorCase(IOERR_DELETE);
            SFSQLiteErrorCase(IOERR_BLOCKED);
            SFSQLiteErrorCase(IOERR_NOMEM);
            SFSQLiteErrorCase(IOERR_ACCESS);
            SFSQLiteErrorCase(IOERR_CHECKRESERVEDLOCK);
            SFSQLiteErrorCase(IOERR_LOCK);
            SFSQLiteErrorCase(IOERR_CLOSE);
            SFSQLiteErrorCase(IOERR_DIR_CLOSE);
            SFSQLiteErrorCase(IOERR_SHMOPEN);
            SFSQLiteErrorCase(IOERR_SHMSIZE);
            SFSQLiteErrorCase(IOERR_SHMLOCK);
            SFSQLiteErrorCase(IOERR_SHMMAP);
            SFSQLiteErrorCase(IOERR_SEEK);
            SFSQLiteErrorCase(IOERR_DELETE_NOENT);
            SFSQLiteErrorCase(IOERR_MMAP);
            SFSQLiteErrorCase(IOERR_GETTEMPPATH);
            SFSQLiteErrorCase(IOERR_CONVPATH);
            SFSQLiteErrorCase(LOCKED_SHAREDCACHE);
            SFSQLiteErrorCase(BUSY_RECOVERY);
            SFSQLiteErrorCase(BUSY_SNAPSHOT);
            SFSQLiteErrorCase(CANTOPEN_NOTEMPDIR);
            SFSQLiteErrorCase(CANTOPEN_ISDIR);
            SFSQLiteErrorCase(CANTOPEN_FULLPATH);
            SFSQLiteErrorCase(CANTOPEN_CONVPATH);
            SFSQLiteErrorCase(CORRUPT_VTAB);
            SFSQLiteErrorCase(READONLY_RECOVERY);
            SFSQLiteErrorCase(READONLY_CANTLOCK);
            SFSQLiteErrorCase(READONLY_ROLLBACK);
            SFSQLiteErrorCase(READONLY_DBMOVED);
            SFSQLiteErrorCase(ABORT_ROLLBACK);
            SFSQLiteErrorCase(CONSTRAINT_CHECK);
            SFSQLiteErrorCase(CONSTRAINT_COMMITHOOK);
            SFSQLiteErrorCase(CONSTRAINT_FOREIGNKEY);
            SFSQLiteErrorCase(CONSTRAINT_FUNCTION);
            SFSQLiteErrorCase(CONSTRAINT_NOTNULL);
            SFSQLiteErrorCase(CONSTRAINT_PRIMARYKEY);
            SFSQLiteErrorCase(CONSTRAINT_TRIGGER);
            SFSQLiteErrorCase(CONSTRAINT_UNIQUE);
            SFSQLiteErrorCase(CONSTRAINT_VTAB);
            SFSQLiteErrorCase(CONSTRAINT_ROWID);
            SFSQLiteErrorCase(NOTICE_RECOVER_WAL);
            SFSQLiteErrorCase(NOTICE_RECOVER_ROLLBACK);
        default: break;
    }
    switch(code) {
            SFSQLiteErrorCase(ERROR);
            SFSQLiteErrorCase(INTERNAL);
            SFSQLiteErrorCase(PERM);
            SFSQLiteErrorCase(ABORT);
            SFSQLiteErrorCase(BUSY);
            SFSQLiteErrorCase(LOCKED);
            SFSQLiteErrorCase(NOMEM);
            SFSQLiteErrorCase(READONLY);
            SFSQLiteErrorCase(INTERRUPT);
            SFSQLiteErrorCase(IOERR);
            SFSQLiteErrorCase(CORRUPT);
            SFSQLiteErrorCase(NOTFOUND);
            SFSQLiteErrorCase(FULL);
            SFSQLiteErrorCase(CANTOPEN);
            SFSQLiteErrorCase(PROTOCOL);
            SFSQLiteErrorCase(SCHEMA);
            SFSQLiteErrorCase(TOOBIG);
            SFSQLiteErrorCase(CONSTRAINT);
            SFSQLiteErrorCase(MISMATCH);
            SFSQLiteErrorCase(MISUSE);
            SFSQLiteErrorCase(RANGE);
            SFSQLiteErrorCase(NOTADB);
        default: break;
    }
    [NSException raise:NSGenericException format:@"%@", reason];
}

@end
