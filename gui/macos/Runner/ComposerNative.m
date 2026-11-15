#import "ComposerNative.h"
#import "Sumi/candidates-bridge.h"
#import "Sumi/candidates-view.h"

@class RappComposerText;
@interface RappComposerView ()
@property(nonatomic,strong) RappComposerText *text;
@property(nonatomic,strong) NSScrollView *scroll;
@property(nonatomic,strong) SumiCandidatesBridge *bridge;
@property(nonatomic,strong) SumiCandidatesView *candidates;
@property(nonatomic,copy) NSDictionary *snapshot, *attributes;
@property(nonatomic,copy) NSString *generation, *hint;
@property(nonatomic,strong) NSColor *hintColor;
@property(nonatomic) CGFloat maxHeight, lineHeight, reportedHeight;
@property(nonatomic) BOOL presented, updating, closed;
// The candidate row stays reserved from its first appearance until the draft empties or focus
// leaves, so the box does not jump between keystrokes.
@property(nonatomic) BOOL reserveRow;
@property(nonatomic,strong) NSMutableArray<void (^)(void)> *pending;
@property(nonatomic,copy) void (^pendingFocus)(id);
- (void)changed;
- (void)drain;
- (void)measure;
@end

@interface RappComposerText : NSTextView
@property(nonatomic,weak) RappComposerView *owner;
@property(nonatomic,copy) NSDictionary *normalSelection;
@property(nonatomic) BOOL editingIME;
@end

@implementation RappComposerText
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    RappComposerView *owner=self.owner;
    NSArray *base=[super validAttributesForMarkedText];
    NSString *marker=owner.bridge.marker;
    return marker?[base arrayByAddingObject:marker]:base;
}
- (BOOL)becomeFirstResponder {
    RappComposerView *owner=self.owner;
    BOOL okay=[super becomeFirstResponder];
    if(okay && owner.event)owner.event(@"focus",@YES,nil);
    return okay;
}
- (BOOL)resignFirstResponder {
    RappComposerView *owner=self.owner;
    BOOL okay=[super resignFirstResponder];
    if(okay){[owner.bridge releaseLease];owner.reserveRow=NO;[owner measure];if(owner.event)owner.event(@"focus",@NO,nil);}
    return okay;
}
- (void)didChangeText {
    RappComposerView *owner=self.owner;
    [super didChangeText];[owner changed];
    if(!self.editingIME)[owner drain];
}
- (void)restoreSelection {
    if(!self.hasMarkedText && self.normalSelection){
        self.selectedTextAttributes=self.normalSelection;self.normalSelection=nil;
    }
}
- (void)setMarkedText:(id)value selectedRange:(NSRange)selected replacementRange:(NSRange)replacement {
    RappComposerView *owner=self.owner;
    // Match Sumi: IME-provided blue backgrounds/fonts never leak into the writing surface.
    NSString *plain=[value isKindOfClass:NSAttributedString.class]?[(NSAttributedString *)value string]:value;
    NSMutableDictionary *attributes=[owner.attributes mutableCopy];
    attributes[NSUnderlineStyleAttributeName]=@(NSUnderlineStyleSingle);
    if(!self.normalSelection)self.normalSelection=self.selectedTextAttributes;
    self.selectedTextAttributes=@{NSBackgroundColorAttributeName:NSColor.clearColor,
                                 NSForegroundColorAttributeName:attributes[NSForegroundColorAttributeName]?:NSColor.textColor};
    self.markedTextAttributes=attributes;
    BOOL wasEditing=self.editingIME;self.editingIME=YES;
    [super setMarkedText:[[NSAttributedString alloc]initWithString:plain attributes:attributes]
          selectedRange:selected replacementRange:replacement];
    self.editingIME=wasEditing;
    [self restoreSelection];[owner changed];[owner drain];
}
- (void)insertText:(id)value replacementRange:(NSRange)replacement {
    RappComposerView *owner=self.owner;
    NSString *plain=[value isKindOfClass:NSAttributedString.class]?[(NSAttributedString *)value string]:value;
    BOOL wasEditing=self.editingIME;self.editingIME=YES;
    [super insertText:[[NSAttributedString alloc]initWithString:plain attributes:owner.attributes]
       replacementRange:replacement];
    self.editingIME=wasEditing;
    self.typingAttributes=owner.attributes;
    [self restoreSelection];[owner drain];
}
- (void)unmarkText {
    RappComposerView *owner=self.owner;
    BOOL wasEditing=self.editingIME;self.editingIME=YES;
    [super unmarkText];self.editingIME=wasEditing;[self restoreSelection];
    if(!self.editingIME)[owner drain];
}
- (void)paste:(id)sender {
    RappComposerView *owner=self.owner;if(owner.event)owner.event(@"paste",nil,nil);}
// The host reads the clipboard (images, files, long text) itself. A plain-text NSTextView would
// disable 粘贴 for an image-only clipboard, and ⌘V would never reach paste:.
- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    if(item.action==@selector(paste:))return self.isEditable;
    return [super validateUserInterfaceItem:item];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if(item.action==@selector(paste:))return self.isEditable;
    return [super validateMenuItem:item];
}
- (void)keyDown:(NSEvent *)event {
    RappComposerView *owner=self.owner;
    NSEventModifierFlags flags=event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    flags &= ~(NSEventModifierFlagNumericPad|NSEventModifierFlagFunction|NSEventModifierFlagCapsLock);
    if(flags==(NSEventModifierFlagControl|NSEventModifierFlagCommand)){
        NSString *key=event.charactersIgnoringModifiers.lowercaseString;
        if([@[@"[",@"]",@"o",@"d"] containsObject:key]){
            if(!event.isARepeat && owner.event)owner.event(@"shortcut",key,nil);
            return;
        }
        if([key isEqual:@"f"]){if(!event.isARepeat)[self.window toggleFullScreen:nil];return;}
    }
    if((flags & ~NSEventModifierFlagShift)==NSEventModifierFlagCommand){
        NSString *key=event.charactersIgnoringModifiers;
        NSString *zoom=nil;
        if([@[@"=",@"+"] containsObject:key])zoom=@"zoom+";
        else if([key isEqual:@"-"])zoom=@"zoom-";
        else if([key isEqual:@"0"] && flags==NSEventModifierFlagCommand)zoom=@"zoom0";
        if(zoom){if(owner.event)owner.event(@"shortcut",zoom,nil);return;}
    }
    if(!self.hasMarkedText && flags==NSEventModifierFlagControl && (event.keyCode==36 || event.keyCode==76)){
        if(!event.isARepeat && owner.event)owner.event(@"toggleFocus",nil,nil);
        return;
    }
    [super keyDown:event];
}
- (void)doCommandBySelector:(SEL)selector {
    RappComposerView *owner=self.owner;
    if(self.hasMarkedText){[super doCommandBySelector:selector];return;}
    if(selector==@selector(insertNewline:)){
        if(NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift)[self insertNewlineIgnoringFieldEditor:nil];
        else if(!NSApp.currentEvent.isARepeat && owner.event)owner.event(@"enter",nil,nil);
        return;
    }
    if(selector==@selector(cancelOperation:)){
        if(owner.event)owner.event(@"escape",nil,nil);return;
    }
    BOOL up=selector==@selector(moveUp:),down=selector==@selector(moveDown:);
    if((up || down) && owner.event){
        NSRange selection=self.selectedRange;
        NSUInteger at=up?selection.location:NSMaxRange(selection);
        NSString *side=up?[self.string substringToIndex:at]:[self.string substringFromIndex:at];
        if([side rangeOfString:@"\n"].location==NSNotFound){
            // The model owns history; only perform normal navigation if it declined, and the
            // same editor/selection still owns focus when its asynchronous answer returns.
            __weak RappComposerText *weak=self;
            NSString *before=[self.string copy];
            owner.event(@"arrow",@(up),^(id taken){
                RappComposerText *text=weak;
                if(text && ![taken boolValue] && text.window.firstResponder==text && !text.hasMarkedText &&
                   [before isEqual:text.string] && NSEqualRanges(selection,text.selectedRange)){
                    if(up)[text moveUp:nil];else [text moveDown:nil];
                }
            });return;
        }
    }
    [super doCommandBySelector:selector];
}
- (void)drawRect:(NSRect)dirty {
    RappComposerView *owner=self.owner;
    [super drawRect:dirty];
    if(!self.string.length && owner.hint.length){
        NSMutableDictionary *attrs=[owner.attributes mutableCopy];
        attrs[NSForegroundColorAttributeName]=owner.hintColor;
        [owner.hint drawInRect:NSMakeRect(self.textContainerOrigin.x,self.textContainerOrigin.y,
             self.textContainer.containerSize.width,owner.lineHeight) withAttributes:attrs];
    }
}
@end

static NSColor *ComposerColor(NSNumber *argb) {
    uint32_t c=argb.unsignedIntValue;
    return [NSColor colorWithSRGBRed:((c>>16)&255)/255.0 green:((c>>8)&255)/255.0
                              blue:(c&255)/255.0 alpha:((c>>24)&255)/255.0];
}

@implementation RappComposerView
- (BOOL)isFlipped {return YES;}
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])){
        _generation=NSUUID.UUID.UUIDString;_lineHeight=22;_maxHeight=300;
        _pending=[NSMutableArray new];
        _attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:15],NSForegroundColorAttributeName:NSColor.textColor};
        _hintColor=NSColor.secondaryLabelColor;
        _bridge=[SumiCandidatesBridge new];
        _candidates=[SumiCandidatesView new];_candidates.hidden=YES;
        NSTextStorage *storage=[NSTextStorage new];NSLayoutManager *layout=[NSLayoutManager new];
        [storage addLayoutManager:layout];
        NSTextContainer *container=[[NSTextContainer alloc]initWithContainerSize:NSMakeSize(1,CGFLOAT_MAX)];
        container.widthTracksTextView=YES;container.lineFragmentPadding=0;[layout addTextContainer:container];
        _text=[[RappComposerText alloc]initWithFrame:NSZeroRect textContainer:container];_text.owner=self;
        _text.richText=NO;_text.importsGraphics=NO;_text.allowsUndo=YES;_text.drawsBackground=NO;
        _text.editable=NO; // enabled by the initial draft, after the previous panel's read
        _text.verticallyResizable=YES;_text.horizontallyResizable=NO;_text.autoresizingMask=NSViewWidthSizable;
        _text.textContainerInset=NSMakeSize(0,13);
        _text.automaticQuoteSubstitutionEnabled=NO;_text.automaticDashSubstitutionEnabled=NO;
        _scroll=[NSScrollView new];_scroll.drawsBackground=NO;_scroll.borderType=NSNoBorder;
        _scroll.hasVerticalScroller=YES;_scroll.autohidesScrollers=YES;_scroll.scrollerStyle=NSScrollerStyleOverlay;
        _scroll.documentView=_text;[self addSubview:_scroll];[self addSubview:_candidates];
        __weak RappComposerView *weak=self;
        _bridge.eligible=^NSString *{
            RappComposerView *v=weak;
            return v && !v.closed && v.window.isKeyWindow && NSApp.isActive && !v.hiddenOrHasHiddenAncestor &&
                v.window.firstResponder==v.text && v.text.editable && v.bounds.size.width>0?v.generation:nil;
        };
        _bridge.prepare=^BOOL(NSDictionary *snapshot){
            RappComposerView *v=weak;if(!v)return NO;
            v.snapshot=snapshot;v.presented=NO;v.candidates.hidden=YES;[v measure];
            return v.snapshot!=nil;
        };
        _bridge.present=^{RappComposerView *v=weak;v.presented=YES;[v measure];};
        _bridge.clear=^{RappComposerView *v=weak;v.snapshot=nil;v.presented=NO;[v.candidates clear];
            v.candidates.hidden=YES;[v measure];};
        _candidates.selectCandidate=^(NSInteger index){[weak.bridge selectIndex:index];};
        _candidates.pageCandidates=^(BOOL next){[weak.bridge pageNext:next];};
        _candidates.layoutChanged=^{[weak measure];};
        // Immediate revocation on window/app deactivation, independent of the heartbeat.
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(deactivate:)
            name:NSWindowDidResignKeyNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(deactivate:)
            name:NSApplicationDidResignActiveNotification object:nil];
    }return self;
}
- (void)deactivate:(NSNotification *)notification {
    if(notification.object==self.window || [notification.name isEqual:NSApplicationDidResignActiveNotification])
        [self.bridge releaseLease];
}
- (void)viewWillMoveToWindow:(NSWindow *)window {
    if(!window){
        [self.bridge releaseLease];
        // Closing a panel preserves the visible composition in its draft and drains queued reads.
        [self.text unmarkText];
    }
    [super viewWillMoveToWindow:window];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if(self.window && self.pendingFocus){
        void (^reply)(id)=self.pendingFocus;self.pendingFocus=nil;
        [self.window makeFirstResponder:self.text];reply(nil);
    }
}
- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];if(hidden)[self.bridge releaseLease];
}
- (void)configure:(NSDictionary *)style {
    CGFloat size=[style[@"size"] doubleValue];if(size<=0)size=15;
    NSMutableArray *families=[NSMutableArray new];
    NSString *familyName=style[@"font"];NSArray *fallback=style[@"fallback"];
    if(familyName && [familyName isKindOfClass:NSString.class])[families addObject:familyName];
    if(fallback && [fallback isKindOfClass:NSArray.class])[families addObjectsFromArray:fallback];
    NSFont *font=nil;NSMutableArray *cascade=[NSMutableArray new];
    for(NSString *family in families){
        if(!font)font=[NSFont fontWithName:family size:size];
        [cascade addObject:[NSFontDescriptor fontDescriptorWithFontAttributes:@{NSFontFamilyAttribute:family}]];
    }
    if(!font)font=[NSFont systemFontOfSize:size];
    font=[NSFont fontWithDescriptor:[font.fontDescriptor fontDescriptorByAddingAttributes:
         @{NSFontCascadeListAttribute:cascade}] size:size]?:font;
    self.lineHeight=MAX(size,[style[@"lineHeight"] doubleValue]);
    self.maxHeight=MAX(48,[style[@"maxHeight"] doubleValue]);
    NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];
    paragraph.minimumLineHeight=self.lineHeight;paragraph.maximumLineHeight=self.lineHeight;
    NSColor *color=ComposerColor(style[@"color"]);
    self.attributes=@{NSFontAttributeName:font,NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:paragraph};
    self.hint=style[@"hint"]?:@"";self.hintColor=ComposerColor(style[@"hintColor"]);
    self.text.font=font;self.text.textColor=color;self.text.insertionPointColor=ComposerColor(style[@"cursor"]);
    self.text.defaultParagraphStyle=paragraph;self.text.typingAttributes=self.attributes;
    // Preserve marked/selection ranges and undo history while applying the same theme everywhere.
    [self.text.textStorage addAttributes:self.attributes range:NSMakeRange(0,self.text.textStorage.length)];
    if(self.text.hasMarkedText){
        NSMutableDictionary *marked=[self.attributes mutableCopy];marked[NSUnderlineStyleAttributeName]=@1;
        self.text.markedTextAttributes=marked;
        self.text.selectedTextAttributes=@{NSBackgroundColorAttributeName:NSColor.clearColor,NSForegroundColorAttributeName:color};
    }
    self.candidates.backgroundColor=NSColor.clearColor;
    self.text.needsDisplay=YES;[self measure];
}
- (void)setFrameSize:(NSSize)size {[super setFrameSize:size];[self measure];}
- (void)measure {
    if(self.updating || self.closed || !self.text)return;
    self.updating=YES;
    // One candidate row (never wrapped: the rest go to local pages) with the body's 13pt inset below.
    const CGFloat inset=13;
    CGFloat width=MAX(1,self.bounds.size.width),gap=0;
    if(self.snapshot){
        if([self.candidates prepareSnapshot:self.snapshot attributes:self.attributes lineHeight:self.lineHeight
                                     width:width maxHeight:MIN(self.lineHeight,MAX(0,self.maxHeight-48-inset))]){
            if(self.candidates.contentHeight>0)self.reserveRow=YES;
        }else{[self.bridge releaseLease];self.reserveRow=NO;}
    }else if(!self.text.string.length)self.reserveRow=NO;
    if(self.reserveRow)gap=self.lineHeight+inset;
    self.text.frame=NSMakeRect(0,0,width,MAX(48,self.text.frame.size.height));
    self.text.textContainer.containerSize=NSMakeSize(width,CGFLOAT_MAX);
    NSTextContainer *container=self.text.textContainer;
    if(!container){self.updating=NO;return;}
    [self.text.layoutManager ensureLayoutForTextContainer:container];
    CGFloat textHeight=ceil([self.text.layoutManager usedRectForTextContainer:container].size.height);
    if(self.text.layoutManager.extraLineFragmentTextContainer)textHeight=MAX(textHeight,NSMaxY(self.text.layoutManager.extraLineFragmentRect));
    CGFloat desired=MIN(self.maxHeight,MAX(48,textHeight+26)+gap);
    CGFloat visible=MAX(0,self.bounds.size.height-gap);
    self.scroll.frame=NSMakeRect(0,0,width,visible);
    self.text.frame=NSMakeRect(0,0,width,MAX(visible,textHeight+26));
    self.candidates.frame=NSMakeRect(0,visible,width,gap);
    self.candidates.hidden=!self.presented || gap<=0;
    self.updating=NO;
    if(fabs(desired-self.reportedHeight)>.1){
        self.reportedHeight=desired;if(self.event)self.event(@"height",@(desired),nil);
    }
    // Flutter must have reserved the native view's requested space before the IME hides its window.
    if(self.snapshot && self.bounds.size.height+.5>=desired)[self.bridge preparedSnapshot];
}
- (void)changed {
    self.text.needsDisplay=YES;[self measure];
    [self.text scrollRangeToVisible:self.text.selectedRange];
    if(self.event)self.event(@"changed",@(!self.text.string.length),nil);
}
- (void)drain {
    if(self.text.hasMarkedText || self.text.editingIME)return;
    while(self.pending.count && !self.text.hasMarkedText){
        void (^next)(void)=self.pending.firstObject;[self.pending removeObjectAtIndex:0];next();
    }
}
- (void)perform:(NSString *)method text:(NSString *)value reply:(void (^)(id))reply {
    if([method isEqual:@"focus"]){
        if(self.window){[self.window makeFirstResponder:self.text];reply(nil);}
        else {if(self.pendingFocus)self.pendingFocus(nil);self.pendingFocus=reply;}
        return;
    }
    if([method isEqual:@"unfocus"]){
        if(self.pendingFocus){self.pendingFocus(nil);self.pendingFocus=nil;}
        [self.bridge releaseLease];
        if(self.window.firstResponder==self.text)[self.window makeFirstResponder:nil];reply(nil);return;
    }
    // All text operations, including read, stay FIFO behind an outstanding composition.
    __weak RappComposerView *weak=self;
    [self.pending addObject:^{
        RappComposerView *view=weak;if(!view){reply(nil);return;}
        if([method isEqual:@"read"]){reply([view.text.string copy]);return;}
        if([method isEqual:@"take"]){
            NSString *text=[view.text.string copy];
            [view.text setString:@""];[view.text.undoManager removeAllActions];
            view.text.typingAttributes=view.attributes;[view changed];reply(text);return;
        }
        if([method isEqual:@"set"]){
            view.text.editable=YES;
            view.text.string=value?:@"";
            [view.text.textStorage setAttributes:view.attributes range:NSMakeRange(0,view.text.textStorage.length)];
            [view.text setSelectedRange:NSMakeRange(view.text.textStorage.length,0)];
            [view.text.undoManager removeAllActions];view.text.typingAttributes=view.attributes;[view changed];
        }else if([method isEqual:@"insert"]){[view.text insertText:value?:@"" replacementRange:view.text.selectedRange];}
        reply(nil);
    }];
    [self drain];
}
- (void)close {
    if(self.pendingFocus){self.pendingFocus(nil);self.pendingFocus=nil;}
    [self.bridge releaseLease];[self.text unmarkText];[self drain];self.closed=YES;
    if(self.window.firstResponder==self.text)[self.window makeFirstResponder:nil];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
@end
