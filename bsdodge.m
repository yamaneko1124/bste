#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <math.h>
#include <stdarg.h>

typedef struct { float x, y; } Vec2;
#define MAXOBJ 256

static NSString *gLogPath = nil;
static void L(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSLog(@"[dodge] %@", s);
    if (gLogPath) { FILE *f = fopen(gLogPath.UTF8String, "a");
        if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); } }
}

static void *hSelf = NULL;
static void *(*fn_domain_get)(void);
static void *(*fn_domain_get_assemblies)(void *, size_t *);
static void *(*fn_assembly_get_image)(void *);
static void *(*fn_class_from_name)(void *, const char *, const char *);
static void *(*fn_class_get_fields)(void *, void **);
static const char *(*fn_field_get_name)(void *);
static size_t (*fn_field_get_offset)(void *);
static void (*fn_field_static_get_value)(void *, void *);
static void *(*fn_class_get_methods)(void *, void **);
static const char *(*fn_method_get_name)(void *);
static uint32_t (*fn_method_get_param_count)(void *);
static void *(*fn_runtime_invoke)(void *, void *, void **, void **);
static void (*fn_thread_attach)(void *);
static void *(*fn_object_get_class)(void *);
static BOOL gReady = NO;

static void ResolveAPI(void) {
    if (hSelf) return;
    char p[1024]; uint32_t sz = sizeof(p);
    _NSGetExecutablePath(p, &sz);
    hSelf = dlopen(p, RTLD_NOW);
    void *h = hSelf ? hSelf : RTLD_DEFAULT;
#define R(n) *(void **)(&fn_##n) = dlsym(h, "il2cpp_" #n)
    R(domain_get); R(domain_get_assemblies); R(assembly_get_image);
    R(class_from_name); R(class_get_fields); R(field_get_name); R(field_get_offset);
    R(field_static_get_value); R(class_get_methods); R(method_get_name);
    R(method_get_param_count); R(runtime_invoke); R(thread_attach); R(object_get_class);
#undef R
    gReady = fn_domain_get && fn_class_from_name && fn_field_get_offset && fn_runtime_invoke;
    L(@"api ready=%d", gReady);
}

static void *FindClass(const char *n) {
    if (!n || !*n) return NULL;
    size_t c = 0;
    void **as = (void **)fn_domain_get_assemblies(fn_domain_get(), &c);
    for (size_t i = 0; i < c; i++) {
        void *k = fn_class_from_name(fn_assembly_get_image(as[i]), "", n);
        if (k) return k;
    }
    return NULL;
}

static void *FieldPtr(void *k, const char *n) {
    if (!k || !n || !*n) return NULL;
    void *it = NULL; void *f;
    while ((f = fn_class_get_fields(k, &it)))
        if (!strcmp(fn_field_get_name(f), n)) return f;
    return NULL;
}

static long FieldOff(void *k, const char *n) {
    void *f = FieldPtr(k, n);
    return f ? (long)fn_field_get_offset(f) : -1;
}

static void *StaticObj(void *k, const char *n) {
    void *f = FieldPtr(k, n);
    if (!f) return NULL;
    void *o = NULL; fn_field_static_get_value(f, &o);
    return o;
}

static void *MethodNamed(void *k, const char *n, uint32_t argc) {
    if (!k || !n || !*n) return NULL;
    void *it = NULL; void *m;
    while ((m = fn_class_get_methods(k, &it))) {
        if (!strcmp(fn_method_get_name(m), n) &&
            fn_method_get_param_count(m) == argc) return m;
    }
    return NULL;
}

static Vec2 ReadPos(void *o, long ox, long oy) {
    Vec2 v = {0, 0};
    if (!o || ox < 0 || oy < 0) return v;
    v.x = *(float *)((char *)o + ox);
    v.y = *(float *)((char *)o + oy);
    return v;
}

static int Collect(void *c, void **out, int cap) {
    if (!c) return 0;
    void *k = fn_object_get_class(c);
    long it = FieldOff(k, "_items"), sz = FieldOff(k, "_size");
    int n = 0;
    if (it >= 0 && sz >= 0) {
        void **arr = *(void ***)((char *)c + it);
        int cnt = *(int *)((char *)c + sz);
        for (int i = 0; i < cnt && n < cap; i++) out[n++] = arr[i];
    } else {
        long ml = FieldOff(k, "max_length");
        if (ml < 0) return 0;
        int cnt = *(int *)((char *)c + ml);
        for (int i = 0; i < cnt && n < cap; i++)
            out[n++] = *(void **)((char *)c + 0x20 + i * 8);
    }
    return n;
}

static NSString *gCharClass, *gCharX, *gCharY;
static NSString *gProjClass, *gProjX, *gProjY;
static NSString *gListField, *gMeField, *gMoveMethod, *gMoveX, *gMoveY;
static NSString *gBattleClass;
static BOOL  gOn = YES, gAlways = NO;
static float gRadius = 1.6f, gHorizon = 0.55f, gStrength = 0.9f;

static void LoadCfg(void) {
    gCharClass = @"LogicCharacter";  gCharX = @"m_x"; gCharY = @"m_y";
    gProjClass = @"LogicProjectile"; gProjX = @"m_x"; gProjY = @"m_y";
    gBattleClass = @"LogicBattleModeClient";
    gListField = @"s_projectiles"; gMeField = @"s_localPlayer";
    gMoveMethod = @"set_move_stick"; gMoveX = @"m_moveX"; gMoveY = @"m_moveY";

    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/dodge.cfg"];
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!txt) return;
    for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
        NSString *l = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!l.length || [l hasPrefix:@"#"] || ![l containsString:@"="]) continue;
        NSArray *kv = [l componentsSeparatedByString:@"="];
        NSString *k = kv[0], *v = kv[1];
        if      ([k isEqual:@"charClass"]) gCharClass = v;
        else if ([k isEqual:@"charX"])     gCharX = v;
        else if ([k isEqual:@"charY"])     gCharY = v;
        else if ([k isEqual:@"projClass"]) gProjClass = v;
        else if ([k isEqual:@"projX"])     gProjX = v;
        else if ([k isEqual:@"projY"])     gProjY = v;
        else if ([k isEqual:@"battleClass"]) gBattleClass = v;
        else if ([k isEqual:@"listField"]) gListField = v;
        else if ([k isEqual:@"meField"])   gMeField = v;
        else if ([k isEqual:@"moveMethod"]) gMoveMethod = v;
        else if ([k isEqual:@"moveX"])     gMoveX = v;
        else if ([k isEqual:@"moveY"])     gMoveY = v;
        else if ([k isEqual:@"radius"])    gRadius = v.floatValue;
        else if ([k isEqual:@"horizon"])   gHorizon = v.floatValue;
        else if ([k isEqual:@"strength"])  gStrength = v.floatValue;
        else if ([k isEqual:@"always"])    gAlways = v.intValue != 0;
    }
    L(@"cfg loaded");
}

static void *kChar, *kProj, *kBattle, *kPlayerCls;
static long offCX = -1, offCY = -1, offPX = -1, offPY = -1, offMX = -1, offMY = -1;
static void *mMove = NULL;

static void ResolveGame(void) {
    if (!gReady || kProj) return;
    fn_thread_attach(fn_domain_get());

    kChar   = FindClass(gCharClass.UTF8String);
    kProj   = FindClass(gProjClass.UTF8String);
    kBattle = FindClass(gBattleClass.UTF8String);
    if (!kBattle) kBattle = FindClass("LogicBattle");
    L(@"classes char=%p proj=%p battle=%p", kChar, kProj, kBattle);
    if (!kChar || !kProj) return;

    offCX = FieldOff(kChar, gCharX.UTF8String);
    offCY = FieldOff(kChar, gCharY.UTF8String);
    offPX = FieldOff(kProj, gProjX.UTF8String);
    offPY = FieldOff(kProj, gProjY.UTF8String);
    if (offCX < 0) { long o = FieldOff(kChar, "m_position"); if (o >= 0) { offCX = o; offCY = o + 4; } }
    if (offPX < 0) { long o = FieldOff(kProj, "m_position"); if (o >= 0) { offPX = o; offPY = o + 4; } }
    L(@"offsets c=(%ld,%ld) p=(%ld,%ld)", offCX, offCY, offPX, offPY);

    const char *pc[] = {"LogicPlayerClient", "LogicCharacterClient", "ClientInput", "GameInput"};
    for (int i = 0; i < 4 && !mMove; i++) {
        kPlayerCls = FindClass(pc[i]);
        if (!kPlayerCls) continue;
        mMove = MethodNamed(kPlayerCls, gMoveMethod.UTF8String, 1);
        if (!mMove) mMove = MethodNamed(kPlayerCls, "SetMoveStick", 1);
        if (!mMove) mMove = MethodNamed(kPlayerCls, "SetMove", 1);
        if (mMove) L(@"move method = %s", pc[i]);
    }
    if (!mMove) {
        offMX = FieldOff(kChar, gMoveX.UTF8String);
        offMY = FieldOff(kChar, gMoveY.UTF8String);
        L(@"no method -> field mode (%ld,%ld)", offMX, offMY);
    }

    for (int i = 0; i < 2; i++) {
        void *k = i ? kProj : kChar; if (!k) continue;
        void *it = NULL; void *f; NSMutableString *s = [NSMutableString string];
        while ((f = fn_class_get_fields(k, &it))) [s appendFormat:@"%s,", fn_field_get_name(f)];
        L(@"fields[%d]=%@", i, s);
    }
    if (kBattle) {
        void *it = NULL; void *f; NSMutableString *s = [NSMutableString string];
        while ((f = fn_class_get_fields(kBattle, &it))) [s appendFormat:@"%s,", fn_field_get_name(f)];
        L(@"fields[battle]=%@", s);
    }
}

static void *LocalPlayer(void) {
    if (kBattle) { void *p = StaticObj(kBattle, gMeField.UTF8String); if (p) return p; }
    return StaticObj(kChar, gMeField.UTF8String);
}

static Vec2 ComputeDodge(void) {
    Vec2 none = {0, 0};
    if (!gOn) return none;
    void *me = LocalPlayer();
    if (!me) return none;

    Vec2 p = ReadPos(me, offCX, offCY);
    if (fabsf(p.x) < 0.001f && fabsf(p.y) < 0.001f) return none;

    void *lst = kBattle ? StaticObj(kBattle, gListField.UTF8String) : NULL;
    if (!lst) lst = StaticObj(kProj, "s_instances");
    if (!lst) return none;

    void *buf[MAXOBJ];
    int n = Collect(lst, buf, MAXOBJ);
    if (n <= 0) return none;

    static void *pv[MAXOBJ]; static Vec2 pp[MAXOBJ]; static int pn = 0;
    Vec2 sum = {0, 0}; float wsum = 0;

    for (int i = 0; i < n; i++) {
        void *pr = buf[i];
        if (!pr || pr == me) continue;
        Vec2 q = ReadPos(pr, offPX, offPY);
        Vec2 vel = {0, 0};
        for (int j = 0; j < pn; j++)
            if (pv[j] == pr) { vel.x = (q.x - pp[j].x) * 60.f; vel.y = (q.y - pp[j].y) * 60.f; break; }

        Vec2 r = { q.x - p.x, q.y - p.y };
        float sp2 = vel.x * vel.x + vel.y * vel.y;
        if (sp2 < 0.01f) continue;

        float t = -(r.x * vel.x + r.y * vel.y) / sp2;
        if (t < 0 || t > gHorizon) continue;

        Vec2 c = { r.x + vel.x * t, r.y + vel.y * t };
        float miss = sqrtf(c.x * c.x + c.y * c.y);
        if (miss > gRadius) continue;

        Vec2 e;
        if (miss < 0.25f) {
            float il = 1.f / sqrtf(sp2);
            e.x = -vel.y * il; e.y = vel.x * il;
            if (r.x * e.x + r.y * e.y < 0) { e.x = -e.x; e.y = -e.y; }
        } else {
            float il = 1.f / miss; e.x = c.x * il; e.y = c.y * il;
        }
        float w = (1.f - t / gHorizon) * (1.f - miss / gRadius);
        sum.x += e.x * w; sum.y += e.y * w; wsum += w;
    }

    pn = 0;
    for (int i = 0; i < n && pn < MAXOBJ; i++) { pv[pn] = buf[i]; pp[pn] = ReadPos(buf[i], offPX, offPY); pn++; }

    if (wsum <= 0.f) return none;
    float l = sqrtf(sum.x * sum.x + sum.y * sum.y);
    if (l < 1e-4f) return none;
    Vec2 d = { sum.x / l * gStrength, sum.y / l * gStrength };
    float dl = sqrtf(d.x * d.x + d.y * d.y);
    if (dl > 1.f) { d.x /= dl; d.y /= dl; }
    return d;
}

static void Apply(Vec2 v) {
    void *me = LocalPlayer();
    if (!me) return;
    if (mMove) {
        void *args[1] = { &v };
        void *exc = NULL;
        fn_runtime_invoke(mMove, me, args, &exc);
    } else if (offMX >= 0 && offMY >= 0) {
        *(float *)((char *)me + offMX) = v.x;
        *(float *)((char *)me + offMY) = v.y;
    }
}

static BOOL gWasThreat = NO;

static void Tick(void) {
    @autoreleasepool {
        if (!gReady) { ResolveAPI(); return; }
        if (!kProj) { ResolveGame(); return; }
        Vec2 d = ComputeDodge();
        BOOL threat = (d.x != 0.f || d.y != 0.f);
        if (threat || gAlways || gWasThreat) Apply(d);
        gWasThreat = threat;
    }
}

static UIView *gPanel = nil;

@interface PanelTarget : NSObject
- (void)pan:(UIPanGestureRecognizer *)g;
- (void)sw:(UISwitch *)s;
- (void)sl:(UISlider *)s;
- (void)step:(CADisplayLink *)l;
@end

@implementation PanelTarget
- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:g.view.superview];
    g.view.center = CGPointMake(g.view.center.x + d.x, g.view.center.y + d.y);
    [g setTranslation:CGPointZero inView:g.view.superview];
}
- (void)sw:(UISwitch *)s { gOn = s.on; }
- (void)sl:(UISlider *)s {
    if (s.tag == 1) gRadius = s.value;
    else if (s.tag == 2) gHorizon = s.value;
    else gStrength = s.value;
}
- (void)step:(CADisplayLink *)l { Tick(); }
@end

static PanelTarget *gTarget = nil;

static void BuildUI(void) {
    UIWindow *w = UIApplication.sharedApplication.windows.firstObject;
    if (!w || gPanel) return;
    gPanel = [[UIView alloc] initWithFrame:CGRectMake(12, 120, 210, 172)];
    gPanel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
    gPanel.layer.cornerRadius = 10;
    [w addSubview:gPanel];
    [gPanel addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gTarget action:@selector(pan:)]];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(10, 6, 190, 22)];
    t.text = @"Dodge"; t.textColor = UIColor.whiteColor;
    t.font = [UIFont boldSystemFontOfSize:14];
    [gPanel addSubview:t];

    UISwitch *s = [[UISwitch alloc] initWithFrame:CGRectMake(10, 32, 51, 31)];
    s.on = gOn;
    [s addTarget:gTarget action:@selector(sw:) forControlEvents:UIControlEventValueChanged];
    [gPanel addSubview:s];

    NSArray *lb = @[@"R", @"T", @"S"];
    for (int i = 0; i < 3; i++) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, 74 + i * 30, 18, 22)];
        l.text = lb[i]; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:12];
        [gPanel addSubview:l];
        UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(30, 74 + i * 30, 168, 22)];
        sl.minimumValue = 0.1f; sl.maximumValue = (i == 2) ? 1.f : 3.f;
        sl.value = (i == 0) ? gRadius : (i == 1 ? gHorizon : gStrength);
        sl.tag = i + 1;
        [sl addTarget:gTarget action:@selector(sl:) forControlEvents:UIControlEventValueChanged];
        [gPanel addSubview:sl];
    }
}

__attribute__((constructor))
static void DodgeInit(void) {
    gLogPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/dodge.log"];
    L(@"=== bsdodge loaded ===");
    LoadCfg();
    gTarget = [PanelTarget new];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        ResolveAPI();
        if (!gReady) return;
        ResolveGame();
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:gTarget selector:@selector(step:)];
        if (@available(iOS 15.0, *))
            link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
        [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        BuildUI();
        L(@"loop started");
    });
}
