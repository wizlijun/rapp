// Standalone AppKit regression probe: compile production code without Flutter or a live remote session.
#import "../Runner/ComposerNative.m"

static void check(BOOL okay, NSString *what) {
    if(!okay){fprintf(stderr,"FAIL: %s\n",what.UTF8String);exit(1);}
}
static NSMutableArray *messages;
static CFDataRef receive(CFMessagePortRef port,SInt32 mid,CFDataRef data,void *info) {
    id value=[NSJSONSerialization JSONObjectWithData:(__bridge NSData *)data options:0 error:nil];
    if(value)[messages addObject:value];return NULL;
}
static void pump(void) {CFRunLoopRunInMode(kCFRunLoopDefaultMode,.02,false);}
static NSDictionary *style(NSNumber *color) {
    return @{@"font":@"Helvetica",@"fallback":@[@"PingFang SC"],@"size":@15,@"lineHeight":@22,
             @"color":color,@"hintColor":@0xff93c9dd,@"cursor":color,@"hint":@"写给 Terminal",@"maxHeight":@180};
}
static NSDictionary *packet(SumiCandidatesBridge *bridge, NSString *type) {
    NSMutableDictionary *m=[[bridge message:type]mutableCopy];m[@"token"]=bridge.token;return m;
}
int main(void) {@autoreleasepool {
    [NSApplication sharedApplication];
    RappComposerView *v=[[RappComposerView alloc]initWithFrame:NSMakeRect(0,0,500,48)];
    [v configure:style(@0xff7dff9e)];
    check(v.text.font.pointSize==15 && v.lineHeight==22,@"body metrics");
    check([[v.text validAttributesForMarkedText]containsObject:v.bridge.marker],@"opt-in marker");
    __block int changed=0;
    v.event=^(NSString *method,id args,void (^reply)(id)){
        if([method isEqual:@"changed"])changed++;
    };
    [v perform:@"set" text:@"草稿 " reply:^(id _){}];
    NSMutableAttributedString *marked=[[NSMutableAttributedString alloc]initWithString:@"ni"
        attributes:@{NSBackgroundColorAttributeName:NSColor.blueColor,NSFontAttributeName:[NSFont systemFontOfSize:30]}];
    [v.text setMarkedText:marked selectedRange:NSMakeRange(2,0) replacementRange:NSMakeRange(NSNotFound,0)];
    NSDictionary *mark=[v.text.textStorage attributesAtIndex:3 effectiveRange:nil];
    check([mark[NSFontAttributeName]pointSize]==15 && !mark[NSBackgroundColorAttributeName],@"preedit uses body style");
    __block NSString *read=nil,*taken=nil;
    [v perform:@"insert" text:@"!" reply:^(id _){}];
    [v perform:@"read" text:nil reply:^(id text){read=text;}];
    [v perform:@"take" text:nil reply:^(id text){taken=text;}];
    check(!read && !taken,@"text operations wait for IME commit");
    [v.text insertText:@"你" replacementRange:NSMakeRange(NSNotFound,0)];
    check([read isEqual:@"草稿 你!"] && [taken isEqual:read] && !v.text.string.length,@"FIFO commit then insert/read/take exactly once");
    check(!v.text.hasMarkedText && v.text.normalSelection==nil,@"normal selection restored");
    [v perform:@"set" text:@"正文保持不变" reply:^(id _){}];
    NSString *before=[v.text.string copy];
    messages=[NSMutableArray new];
    NSString *replyName=[SumiCandidateReplyPrefix stringByAppendingString:NSUUID.UUID.UUIDString];
    CFMessagePortRef port=CFMessagePortCreateLocal(NULL,(__bridge CFStringRef)replyName,receive,NULL,NULL);
    check(port!=NULL,@"test IME port");
    CFRunLoopSourceRef source=CFMessagePortCreateRunLoopSource(NULL,port,0);
    CFRunLoopAddSource(CFRunLoopGetMain(),source,kCFRunLoopDefaultMode);
    v.bridge.eligible=^NSString *{return @"test-document";};
    [v.bridge receive:@{@"v":@1,@"type":@"hello",@"token":v.bridge.token,@"context":@"ctx",@"reply":replyName}];
    pump();check([messages.lastObject[@"type"]isEqual:@"ready"],@"hello/ready handshake");
    NSMutableDictionary *snapshot=[packet(v.bridge,@"snapshot")mutableCopy];
    snapshot[@"serial"]=@"1";snapshot[@"cursor"]=@0;snapshot[@"hasPrev"]=@NO;snapshot[@"hasNext"]=@YES;
    snapshot[@"candidates"]=@[@{@"index":@0,@"text":@"你好",@"label":@"1",@"comment":@""},
                              @{@"index":@1,@"text":@"拟好",@"label":@"2",@"comment":@""}];
    [v.bridge receive:snapshot];pump();
    check(!v.bridge.prepared && v.candidates.hidden,@"no prepared ACK before Flutter expands the view");
    [v setFrameSize:NSMakeSize(500,v.reportedHeight)];pump();
    check([messages.lastObject[@"type"]isEqual:@"prepared"] && v.candidates.hidden,@"layout prepared, still not presented");
    NSMutableDictionary *present=[packet(v.bridge,@"present")mutableCopy];present[@"serial"]=@"1";
    [v.bridge receive:present];
    check(!v.candidates.hidden && [before isEqual:v.text.string],@"candidate present does not change body");
    NSDictionary *candidate=[v.candidates.items.firstObject.text attributesAtIndex:2 effectiveRange:nil];
    check([candidate[NSForegroundColorAttributeName]isEqual:v.attributes[NSForegroundColorAttributeName]] &&
          [candidate[NSFontAttributeName]isEqual:v.attributes[NSFontAttributeName]],@"candidates inherit exact font and color");
    for(NSNumber *color in @[@0xff7dff9e,@0xffe9faff,@0xfff4f4f2]){
        [v configure:style(color)];
        NSDictionary *a=[v.candidates.items.firstObject.text attributesAtIndex:2 effectiveRange:nil];
        check([a[NSForegroundColorAttributeName]isEqual:v.attributes[NSForegroundColorAttributeName]],@"theme changes affect body and candidates together");
    }
    NSBitmapImageRep *image=[v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:image];
    [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:@"/tmp/rapp-composer-native.png" atomically:YES];
    NSUInteger count=messages.count;
    [v.bridge selectIndex:1];[v.bridge selectIndex:1];pump();
    check(messages.count==count+1 && [messages.lastObject[@"type"]isEqual:@"select"] &&
          [messages.lastObject[@"index"]intValue]==1,@"selection uses original index and cannot duplicate");
    [v.bridge receive:present];[v.bridge selectIndex:1];pump();
    check(messages.count==count+1,@"duplicate present cannot re-enable consumed selection");
    NSMutableDictionary *stale=[packet(v.bridge,@"release")mutableCopy];stale[@"lease"]=NSUUID.UUID.UUIDString;
    [v.bridge receive:stale];check(v.bridge.connected,@"old release cannot revoke current lease");
    v.bridge.lastSeen=CACurrentMediaTime()-2;[v.bridge checkLease];
    check(!v.bridge.connected && v.candidates.hidden && [before isEqual:v.text.string],@"timeout clears candidates without touching text");
    pump();
    [v.bridge receive:@{@"v":@1,@"type":@"hello",@"token":v.bridge.token,@"context":@"ctx2",@"reply":replyName}];
    pump();
    NSMutableArray *many=[NSMutableArray new];
    for(int i=0;i<35;i++)[many addObject:@{@"index":@(i),@"text":@"很长的中文候选词",@"label":[NSString stringWithFormat:@"%d",i+1],@"comment":@""}];
    snapshot=[packet(v.bridge,@"snapshot")mutableCopy];
    [snapshot addEntriesFromDictionary:@{@"serial":@"2",@"cursor":@17,@"hasPrev":@NO,@"hasNext":@NO,@"candidates":many}];
    [v setFrameSize:NSMakeSize(120,180)];[v.bridge receive:snapshot];
    present=[packet(v.bridge,@"present")mutableCopy];present[@"serial"]=@"2";[v.bridge receive:present];
    check(v.candidates.rowCount<=4 && v.candidates.localPageCount>1 && v.candidates.localPage>0,@"narrow layout has at most four rows and follows selected candidate");
    check([v.candidates.items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SumiCandidateItem *item,id _){return !item.action && item.candidateIndex==17;}]].count==1,@"local pages preserve original candidate indices");
    [v setFrameSize:NSMakeSize(1,180)];
    check(!v.bridge.connected && v.candidates.hidden,@"insufficient space releases the default candidate window");
    [v setFrameSize:NSMakeSize(500,48)];
    [v.text setMarkedText:@"shi" selectedRange:NSMakeRange(3,0) replacementRange:NSMakeRange(NSNotFound,0)];
    __block NSString *detached=nil;[v perform:@"read" text:nil reply:^(id text){detached=text;}];
    [v viewWillMoveToWindow:nil];
    check(detached!=nil && [detached hasSuffix:@"shi"],@"detach preserves visible preedit and drains draft read");
    [v close];CFRunLoopRemoveSource(CFRunLoopGetMain(),source,kCFRunLoopDefaultMode);CFRelease(source);CFMessagePortInvalidate(port);CFRelease(port);
    printf("PASS: native composition/FIFO, theme inheritance, bridge handoff, stale/duplicate rejection, timeout, detach (%d changes)\n",changed);
}return 0;}
