#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the given block inside an Objective-C @try/@catch.
/// Returns the caught NSException, or nil if the block succeeded.
NSException * _Nullable ObjCTryCatch(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
