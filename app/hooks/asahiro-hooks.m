// macos side hooks loaded into the bundled wine with DYLD_INSERT_LIBRARIES, each one is off unless its variable is set.
// ASAHIRO_FRAME_CAP paces d3dmetal: it presents with -[MTLCommandBuffer presentDrawable:], which shows frames as soon as
// they are ready, so a capped game lands on uneven vsyncs. presentDrawable:afterMinimumDuration: keeps every frame up for
// the same number of refreshes. ASAHIRO_DOCK_ICON names an icon wine shows in the dock instead of the exe's square one.
// ASAHIRO_NATIVE_FULLSCREEN moves the window wine shows over the whole screen into a macos fullscreen space, the only
// place metal presents direct to display instead of through the window server's compositor.
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <dispatch/dispatch.h>

typedef void (*present_fn)(id, SEL, id);
typedef void (*present_min_fn)(id, SEL, id, double);
typedef void (*set_fn)(id, SEL, id);
typedef void (*void_fn)(id, SEL);
typedef void (*behavior_fn)(id, SEL, unsigned long);

static double min_duration;
static const char *dock_icon_path;
static int icon_hooked, fullscreen_hooked, native_fullscreen, debug;
#define DBG(...) do { if (debug) fprintf(stderr, "asahiro-hooks: " __VA_ARGS__); } while (0)
static id dock_icon;
static Class app_class;
static set_fn set_icon_orig, set_view_orig;
static SEL sel_present, sel_present_min, sel_drawable_min;
static __thread int depth, setting_icon;

// each class keeps its own original so a subclass calling super, or a wrapper forwarding to the
// real command buffer, reaches the next implementation instead of pacing the same frame twice
static void pace_class(Class cls) {
    Method m = NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel_present) m = methods[i];
    }
    free(methods);
    if (!m || !class_respondsToSelector(cls, sel_present_min)) return;
    present_fn orig = (present_fn)method_getImplementation(m);
    IMP paced = imp_implementationWithBlock(^(id self, id drawable) {
        static int told;
        if (!told && drawable) {
            told = 1;
            fprintf(stderr, "asahiro-hooks: %s presents %s\n", class_getName(object_getClass(self)), class_getName(object_getClass(drawable)));
        }
        // the paced call ends in -[drawable presentAfterMinimumDuration:], which not every drawable class has
        if (depth > 0 || !drawable || !class_respondsToSelector(object_getClass(drawable), sel_drawable_min)) {
            orig(self, sel_present, drawable);
            return;
        }
        depth++;
        ((present_min_fn)objc_msgSend)(self, sel_present_min, drawable, min_duration);
        depth--;
    });
    method_setImplementation(m, paced);
}

static id load_dock_icon(void) {
    if (!dock_icon) {
        id path = ((id (*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), dock_icon_path);
        id image = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSImage"), sel_registerName("alloc"));
        dock_icon = ((id (*)(id, SEL, id))objc_msgSend)(image, sel_registerName("initWithContentsOfFile:"), path);
    }
    return dock_icon;
}

// wine sets the exe's icon on the application, and crossover can also put a view on the app's dock tile.
// both end up showing our icon instead, the view would cover the application icon otherwise.
// the blocks capture nothing that is an object, copying one would message appkit classes before appkit is set up
static void hook_icon(void) {
    app_class = objc_getClass("NSApplication");
    Class tile = objc_getClass("NSDockTile");
    Method set_icon = app_class ? class_getInstanceMethod(app_class, sel_registerName("setApplicationIconImage:")) : NULL;
    Method set_view = tile ? class_getInstanceMethod(tile, sel_registerName("setContentView:")) : NULL;
    if (!set_icon || !set_view) return;
    DBG("icon hooks installed in pid %d\n", getpid());
    icon_hooked = 1;
    set_icon_orig = (set_fn)method_getImplementation(set_icon);
    method_setImplementation(set_icon, imp_implementationWithBlock(^(id self, id image) {
        id ours = load_dock_icon();
        DBG("setApplicationIconImage %p, ours %p\n", image, ours);
        setting_icon++;
        set_icon_orig(self, sel_registerName("setApplicationIconImage:"), ours ? ours : image);
        setting_icon--;
    }));
    set_view_orig = (set_fn)method_getImplementation(set_view);
    method_setImplementation(set_view, imp_implementationWithBlock(^(id self, id view) {
        id nsapp = ((id (*)(id, SEL))objc_msgSend)((id)app_class, sel_registerName("sharedApplication"));
        id app_tile = ((id (*)(id, SEL))objc_msgSend)(nsapp, sel_registerName("dockTile"));
        DBG("setContentView %p on %s tile, nested %d\n", view, self == app_tile ? "app" : "other", setting_icon);
        // appkit sets the tile's view itself while applying an application icon, that one passes through
        if (!setting_icon && self == app_tile && view && load_dock_icon()) {
            set_view_orig(self, sel_registerName("setContentView:"), nil);
            setting_icon++;
            set_icon_orig(nsapp, sel_registerName("setApplicationIconImage:"), dock_icon);
            setting_icon--;
            return;
        }
        set_view_orig(self, sel_registerName("setContentView:"), view);
    }));
}

// NSWindowStyleMaskFullScreen and the fullscreen collection behaviors, appkit's headers are left out so the
// hooks never pull appkit into a wine process before wine loads it
#define STYLE_FULLSCREEN (1UL << 14)
#define BEHAVIOR_PRIMARY (1UL << 7)
#define BEHAVIOR_AUXILIARY (1UL << 8)
static char moved_key;
static void_fn update_fullscreen_orig;
static behavior_fn adjust_behavior_orig;
static set_fn ns_toggle_fullscreen;

static int moved(id window) {
    return objc_getAssociatedObject(window, &moved_key) != nil;
}

// wine only lets resizable windows into a fullscreen space and takes them back out otherwise, its own toggle
// also refuses maximized windows, so the moved window keeps the primary behavior and enters through NSWindow.
// a window someone takes out of fullscreen stays marked and is not pushed back in
static void hook_fullscreen(void) {
    Class wine_window = objc_getClass("WineWindow");
    Class ns_window = objc_getClass("NSWindow");
    Method update = wine_window ? class_getInstanceMethod(wine_window, sel_registerName("updateFullscreen")) : NULL;
    Method adjust = wine_window ? class_getInstanceMethod(wine_window, sel_registerName("adjustFullScreenBehavior:")) : NULL;
    Method toggle = ns_window ? class_getInstanceMethod(ns_window, sel_registerName("toggleFullScreen:")) : NULL;
    if (!update || !adjust || !toggle) return;
    fullscreen_hooked = 1;
    DBG("fullscreen hooks installed in pid %d\n", getpid());
    ns_toggle_fullscreen = (set_fn)method_getImplementation(toggle);
    adjust_behavior_orig = (behavior_fn)method_getImplementation(adjust);
    method_setImplementation(adjust, imp_implementationWithBlock(^(id self, unsigned long behavior) {
        if (!moved(self)) {
            adjust_behavior_orig(self, sel_registerName("adjustFullScreenBehavior:"), behavior);
            return;
        }
        behavior = (behavior | BEHAVIOR_PRIMARY) & ~BEHAVIOR_AUXILIARY;
        if (behavior != ((unsigned long (*)(id, SEL))objc_msgSend)(self, sel_registerName("collectionBehavior")))
            ((void (*)(id, SEL, unsigned long))objc_msgSend)(self, sel_registerName("setCollectionBehavior:"), behavior);
    }));
    update_fullscreen_orig = (void_fn)method_getImplementation(update);
    method_setImplementation(update, imp_implementationWithBlock(^(id self) {
        update_fullscreen_orig(self, sel_registerName("updateFullscreen"));
        // isFullscreen is wine's own test, the window covers a whole screen outside a fullscreen space
        if (moved(self) || !((BOOL (*)(id, SEL))objc_msgSend)(self, sel_registerName("isFullscreen"))) return;
        objc_setAssociatedObject(self, &moved_key, (id)objc_getClass("NSObject"), OBJC_ASSOCIATION_ASSIGN);
        DBG("moving %p into a fullscreen space\n", self);
        // appkit refuses to start the transition from inside wine's frame update
        dispatch_async(dispatch_get_main_queue(), ^{
            unsigned long style = ((unsigned long (*)(id, SEL))objc_msgSend)(self, sel_registerName("styleMask"));
            if (style & STYLE_FULLSCREEN) return;
            ((void (*)(id, SEL, unsigned long))objc_msgSend)(self, sel_registerName("adjustFullScreenBehavior:"),
                ((unsigned long (*)(id, SEL))objc_msgSend)(self, sel_registerName("collectionBehavior")));
            ns_toggle_fullscreen(self, sel_registerName("toggleFullScreen:"), nil);
        });
    }));
}

// the classes that implement presentDrawable:, the gpu drivers' own command buffers inherit metal's.
// the others wrap the real command buffer for the metal hud, validation and the metal 3 on 4 layer
static const char *paced_classes[] = { "_MTLCommandBuffer", "MTLToolsCommandBuffer", "MTLCountersCommandBuffer", "MTL3On4CommandBuffer" };
#define PACED_COUNT (sizeof(paced_classes) / sizeof(paced_classes[0]))
static int paced[PACED_COUNT];

// wine dlopens appkit, metal and the gpu driver, and objc only registers a dlopened image's classes after
// dyld calls this, so each class is looked up by name on every load until it turns up. a name lookup is
// cheap, unlike listing an image's classes, and dyld calls this without objc's runtime lock held
static void image_loaded(const struct mach_header *mh, intptr_t slide) {
    if (dock_icon_path && !icon_hooked) hook_icon();
    if (native_fullscreen && !fullscreen_hooked) hook_fullscreen();
    if (min_duration <= 0) return;
    for (unsigned int i = 0; i < PACED_COUNT; i++) {
        if (paced[i]) continue;
        Class cls = objc_getClass(paced_classes[i]);
        if (cls) {
            paced[i] = 1;
            pace_class(cls);
            DBG("pacing %s in pid %d\n", paced_classes[i], getpid());
        }
    }
}

__attribute__((constructor)) static void hooks_init(void) {
    const char *cap = getenv("ASAHIRO_FRAME_CAP");
    double fps = cap ? atof(cap) : 0;
    // half a millisecond of slack so timer jitter never pushes a frame onto the vsync after its slot
    if (fps > 0) min_duration = 1.0 / fps - 0.0005;
    dock_icon_path = getenv("ASAHIRO_DOCK_ICON");
    native_fullscreen = getenv("ASAHIRO_NATIVE_FULLSCREEN") != NULL;
    debug = getenv("ASAHIRO_HOOKS_DEBUG") != NULL;
    DBG("loaded in pid %d, cap %s, icon %s\n", getpid(), cap ? cap : "none", dock_icon_path ? dock_icon_path : "none");
    if (min_duration <= 0 && !dock_icon_path && !native_fullscreen) return;
    sel_present = sel_registerName("presentDrawable:");
    sel_present_min = sel_registerName("presentDrawable:afterMinimumDuration:");
    sel_drawable_min = sel_registerName("presentAfterMinimumDuration:");
    _dyld_register_func_for_add_image(image_loaded);
}
