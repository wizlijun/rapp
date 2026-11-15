#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
/// One session's editor. Text stays in NSTextStorage; the channel only reads on demand.
@interface RappComposerView : NSView
@property(nonatomic,copy,nullable) void (^event)(NSString *, id _Nullable, void (^ _Nullable)(id _Nullable));
- (void)configure:(NSDictionary *)style;
- (void)perform:(NSString *)method text:(nullable NSString *)text reply:(void (^)(id _Nullable))reply;
- (void)close;
@end
NS_ASSUME_NONNULL_END
