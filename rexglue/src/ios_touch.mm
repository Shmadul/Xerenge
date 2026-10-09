// The on-screen controls (iOS): translucent buttons over the game, working an
// SDL virtual gamepad that the SDK's SDL input driver opens like any pad that
// is plugged in (SDL_EVENT_GAMEPAD_ADDED).
//
//   left half      a floating stick: where the thumb lands is its centre
//   right, low     RT (accelerate) and LT (brake)
//   right, middle  A B X Y
//   top corners    LB and RB; top middle Back and Start
//
// The overlay hides itself while a real controller is connected, and comes
// back when it goes. Nothing here runs until the game has brought SDL's
// joystick subsystem and its window up; a timer on the main run loop (which
// SDL pumps) waits for both.

#import <UIKit/UIKit.h>

#include <SDL3/SDL.h>

#include <cmath>
#include <vector>

namespace {

struct Control {
  const char* label;
  int button;   // SDL_GamepadButton, or -1
  int trigger;  // SDL_GamepadAxis, or -1
  CGFloat fx, fy, fr;  // centre in fractions of the width/height; radius in units
  CGPoint centre;
  CGFloat radius;
  bool down;
  CAShapeLayer* shape;
  CATextLayer* text;
};

SDL_Joystick* g_pad = nullptr;
SDL_JoystickID g_pad_id = 0;

SDL_Joystick* Pad() {
  if (g_pad || !SDL_WasInit(SDL_INIT_JOYSTICK)) {
    return g_pad;
  }
  SDL_VirtualJoystickDesc desc;
  SDL_INIT_INTERFACE(&desc);
  desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
  desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
  desc.nbuttons = SDL_GAMEPAD_BUTTON_DPAD_RIGHT + 1;
  desc.axis_mask = (1u << SDL_GAMEPAD_AXIS_COUNT) - 1;
  desc.button_mask = (1u << (SDL_GAMEPAD_BUTTON_DPAD_RIGHT + 1)) - 1;
  desc.name = "Xerenge touch controls";
  g_pad_id = SDL_AttachVirtualJoystick(&desc);
  if (g_pad_id) {
    g_pad = SDL_OpenJoystick(g_pad_id);
  }
  return g_pad;
}

void SetButton(int button, bool down) {
  if (SDL_Joystick* pad = Pad()) {
    SDL_SetJoystickVirtualButton(pad, button, down);
  }
}

// value -1..1 for the sticks, 0..1 for the triggers. A virtual gamepad's
// trigger rests at the bottom of the axis range (SDL_virtualjoystick.c), so 0
// is SDL_JOYSTICK_AXIS_MIN there - the middle of the range would read as half
// pressed, and a released brake would keep holding the car back.
void SetAxis(int axis, float value) {
  if (SDL_Joystick* pad = Pad()) {
    const bool trigger =
        axis == SDL_GAMEPAD_AXIS_LEFT_TRIGGER || axis == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER;
    float raw = trigger ? SDL_JOYSTICK_AXIS_MIN +
                              value * float(SDL_JOYSTICK_AXIS_MAX - SDL_JOYSTICK_AXIS_MIN)
                        : value * SDL_JOYSTICK_AXIS_MAX;
    raw = std::fmax(float(SDL_JOYSTICK_AXIS_MIN), std::fmin(float(SDL_JOYSTICK_AXIS_MAX), raw));
    SDL_SetJoystickVirtualAxis(pad, axis, Sint16(raw));
  }
}

// Whether a controller other than ours is connected.
bool RealControllerConnected() {
  int count = 0;
  SDL_JoystickID* ids = SDL_GetGamepads(&count);
  bool real = false;
  for (int i = 0; i < count; ++i) {
    if (ids[i] != g_pad_id) {
      real = true;
    }
  }
  SDL_free(ids);
  return real;
}

}  // namespace

@interface XerengeTouchControls : UIView
@end

@implementation XerengeTouchControls {
  std::vector<Control> _controls;
  CAShapeLayer* _stickBase;
  CAShapeLayer* _stickKnob;
  CGPoint _stickRest, _stickCentre;
  CGFloat _stickRadius;
  UITouch* _stickTouch;
  NSMapTable<UITouch*, NSNumber*>* _touchControl;  // touch -> index into _controls
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.multipleTouchEnabled = YES;
    self.backgroundColor = UIColor.clearColor;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _touchControl = [NSMapTable weakToStrongObjectsMapTable];
    _controls = {
        {"RT", -1, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, 0.90, 0.76, 1.00},
        {"LT", -1, SDL_GAMEPAD_AXIS_LEFT_TRIGGER, 0.75, 0.84, 0.80},
        {"A", SDL_GAMEPAD_BUTTON_SOUTH, -1, 0.84, 0.47, 0.45},
        {"B", SDL_GAMEPAD_BUTTON_EAST, -1, 0.92, 0.33, 0.45},
        {"X", SDL_GAMEPAD_BUTTON_WEST, -1, 0.76, 0.33, 0.45},
        {"Y", SDL_GAMEPAD_BUTTON_NORTH, -1, 0.84, 0.19, 0.45},
        {"LB", SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, -1, 0.07, 0.12, 0.50},
        {"RB", SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, -1, 0.66, 0.12, 0.50},
        {"Back", SDL_GAMEPAD_BUTTON_BACK, -1, 0.40, 0.09, 0.38},
        {"Start", SDL_GAMEPAD_BUTTON_START, -1, 0.52, 0.09, 0.38},
    };
    for (Control& control : _controls) {
      control.shape = [self circleLayer];
      control.text = [CATextLayer layer];
      control.text.string = @(control.label);
      control.text.alignmentMode = kCAAlignmentCenter;
      control.text.foregroundColor = [UIColor colorWithWhite:0.08 alpha:0.75].CGColor;
      control.text.contentsScale = UIScreen.mainScreen.scale;
      [self.layer addSublayer:control.shape];
      [self.layer addSublayer:control.text];
    }
    _stickBase = [self circleLayer];
    _stickKnob = [self circleLayer];
    [self.layer addSublayer:_stickBase];
    [self.layer addSublayer:_stickKnob];
  }
  return self;
}

- (CAShapeLayer*)circleLayer {
  CAShapeLayer* layer = [CAShapeLayer layer];
  layer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
  layer.fillColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
  return layer;
}

- (void)setCircle:(CAShapeLayer*)layer centre:(CGPoint)c radius:(CGFloat)r down:(bool)down {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  layer.path = [UIBezierPath bezierPathWithArcCenter:c radius:r startAngle:0 endAngle:2 * M_PI
                                           clockwise:YES].CGPath;
  layer.fillColor = [UIColor colorWithWhite:1.0 alpha:down ? 0.45 : 0.18].CGColor;
  [CATransaction commit];
}

// Laid out inside the safe area, so nothing sits under the Dynamic Island or
// the home indicator.
- (void)layoutSubviews {
  [super layoutSubviews];
  const CGRect area = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
  const CGFloat unit = std::fmin(area.size.width, area.size.height) / 7.0;
  for (Control& control : _controls) {
    control.centre = CGPointMake(area.origin.x + control.fx * area.size.width,
                                 area.origin.y + control.fy * area.size.height);
    control.radius = control.fr * unit;
    [self setCircle:control.shape centre:control.centre radius:control.radius down:control.down];
    const CGFloat font = 0.36 * unit;
    control.text.fontSize = font;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    control.text.frame = CGRectMake(control.centre.x - control.radius,
                                    control.centre.y - font * 0.62, control.radius * 2, font * 1.3);
    [CATransaction commit];
  }
  _stickRadius = 1.15 * unit;
  _stickRest = CGPointMake(area.origin.x + 0.17 * area.size.width,
                           area.origin.y + 0.66 * area.size.height);
  _stickBase.lineWidth = _stickKnob.lineWidth = 0.06 * unit;
  for (Control& control : _controls) {
    control.shape.lineWidth = 0.06 * unit;
  }
  if (!_stickTouch) {
    _stickCentre = _stickRest;
    [self drawStickAt:_stickRest];
  }
}

- (void)drawStickAt:(CGPoint)knob {
  [self setCircle:_stickBase centre:_stickCentre radius:_stickRadius down:false];
  [self setCircle:_stickKnob centre:knob radius:_stickRadius * 0.45 down:_stickTouch != nil];
}

- (int)hit:(CGPoint)p {
  int best = -1;
  CGFloat best_distance = CGFLOAT_MAX;
  for (size_t i = 0; i < _controls.size(); ++i) {
    const CGFloat d = std::hypot(p.x - _controls[i].centre.x, p.y - _controls[i].centre.y);
    if (d < _controls[i].radius * 1.25 && d < best_distance) {
      best = int(i);
      best_distance = d;
    }
  }
  return best;
}

- (void)press:(int)index down:(bool)down {
  Control& control = _controls[index];
  if (control.down == down) {
    return;
  }
  control.down = down;
  if (control.trigger >= 0) {
    SetAxis(control.trigger, down ? 1.0f : 0.0f);
  } else {
    SetButton(control.button, down);
  }
  [self setCircle:control.shape centre:control.centre radius:control.radius down:down];
}

// A finger on a button holds whichever button it is over, so a thumb can roll
// from the accelerator to the brake without lifting.
- (void)moveTouch:(UITouch*)touch to:(int)index {
  NSNumber* previous = [_touchControl objectForKey:touch];
  if (previous && previous.intValue == index) {
    return;
  }
  [_touchControl removeObjectForKey:touch];
  if (previous && ![self isHeldByOtherTouch:previous.intValue]) {
    [self press:previous.intValue down:false];
  }
  if (index >= 0) {
    [_touchControl setObject:@(index) forKey:touch];
    [self press:index down:true];
  }
}

- (bool)isHeldByOtherTouch:(int)index {
  for (UITouch* t in _touchControl) {
    if ([_touchControl objectForKey:t].intValue == index) {
      return true;
    }
  }
  return false;
}

- (void)moveStick:(CGPoint)p {
  CGFloat dx = p.x - _stickCentre.x, dy = p.y - _stickCentre.y;
  const CGFloat length = std::hypot(dx, dy);
  if (length > _stickRadius) {
    dx *= _stickRadius / length;
    dy *= _stickRadius / length;
  }
  SetAxis(SDL_GAMEPAD_AXIS_LEFTX, float(dx / _stickRadius));
  SetAxis(SDL_GAMEPAD_AXIS_LEFTY, float(dy / _stickRadius));
  [self drawStickAt:CGPointMake(_stickCentre.x + dx, _stickCentre.y + dy)];
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  for (UITouch* touch in touches) {
    const CGPoint p = [touch locationInView:self];
    const int index = [self hit:p];
    if (index >= 0) {
      [self moveTouch:touch to:index];
    } else if (!_stickTouch && p.x < self.bounds.size.width * 0.5) {
      _stickTouch = touch;
      _stickCentre = p;
      [self moveStick:p];
    }
  }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  for (UITouch* touch in touches) {
    const CGPoint p = [touch locationInView:self];
    if (touch == _stickTouch) {
      [self moveStick:p];
    } else if ([_touchControl objectForKey:touch]) {
      [self moveTouch:touch to:[self hit:p]];
    }
  }
}

- (void)endTouches:(NSSet<UITouch*>*)touches {
  for (UITouch* touch in touches) {
    if (touch == _stickTouch) {
      _stickTouch = nil;
      _stickCentre = _stickRest;
      SetAxis(SDL_GAMEPAD_AXIS_LEFTX, 0.0f);
      SetAxis(SDL_GAMEPAD_AXIS_LEFTY, 0.0f);
      [self drawStickAt:_stickRest];
    } else {
      [self moveTouch:touch to:-1];
    }
  }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  [self endTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  [self endTouches:touches];
}

// Everything let go: when a real controller takes over.
- (void)releaseAll {
  NSMutableSet<UITouch*>* touches = [NSMutableSet set];
  for (UITouch* t in _touchControl) {
    [touches addObject:t];
  }
  if (_stickTouch) {
    [touches addObject:_stickTouch];
  }
  [self endTouches:touches];
}

@end

namespace {

XerengeTouchControls* g_overlay = nil;

UIView* GameView() {
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) {
      continue;
    }
    for (UIWindow* window in ((UIWindowScene*)scene).windows) {
      if (window.rootViewController.view) {
        return window.rootViewController.view;
      }
    }
  }
  return nil;
}

}  // namespace

// Called from the iOS launcher (ios_launch.mm) on the main thread, before
// the game starts.
extern "C" void XerengeIOSStartTouchControls() {
  [NSTimer scheduledTimerWithTimeInterval:0.5
                                  repeats:YES
                                    block:^(NSTimer*) {
                                      if (!g_overlay) {
                                        UIView* view = GameView();
                                        if (!view || !Pad()) {
                                          return;
                                        }
                                        g_overlay = [[XerengeTouchControls alloc]
                                            initWithFrame:view.bounds];
                                        [view addSubview:g_overlay];
                                      }
                                      const bool hide = RealControllerConnected();
                                      if (hide && !g_overlay.hidden) {
                                        [g_overlay releaseAll];
                                      }
                                      g_overlay.hidden = hide;
                                      [g_overlay.superview bringSubviewToFront:g_overlay];
                                    }];
}
