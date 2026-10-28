unit uHmiWidgets;

{ Immediate-mode widgets for the factory HMI (raylib, design coordinates 1600x900).

  A button acts on release, and only when both the press and the release were inside it,
  so a finger that slides off a button on a touch panel cancels the action.
  While a modal dialog is open, widgets of layer 0 ignore input. }

{$mode objfpc}{$H+}

interface

uses
  raylib, uHmiTheme;

type
  TButtonStyle = (bsNormal, bsPrimary, bsDanger, bsGhost);

var
  UiMouse: TVector2;          // mouse in design coordinates
  UiPressPos: TVector2;       // where the current press started
  UiPressed, UiReleased, UiDown: Boolean;
  UiModalLayer: Integer;      // 0 = none, 1 = dialog open
  UiHand: Boolean;            // set by widgets under the mouse -> pointing-hand cursor
  UiEnabled: Boolean = True;  // False in screenshot / headless mode

procedure UiBeginFrame(Zoom, OffX, OffY: Single);
procedure UiEndFrame;

function Hover(const R: TRectangle; Layer: Integer = 0): Boolean;
function Clicked(const R: TRectangle; Layer: Integer = 0): Boolean;
function Button(const R: TRectangle; const Caption: string; Style: TButtonStyle = bsNormal;
  Enabled: Boolean = True; Layer: Integer = 0): Boolean;
function Tab(const R: TRectangle; const Caption, Hint: string; Active: Boolean;
  Badge: Integer; const BadgeColor: TColor): Boolean;

implementation

uses
  SysUtils;

function InRect(const P: TVector2; const R: TRectangle): Boolean;
begin
  Result := (P.x >= R.x) and (P.x < R.x + R.width) and (P.y >= R.y) and (P.y < R.y + R.height);
end;

procedure UiBeginFrame(Zoom, OffX, OffY: Single);
var
  m: TVector2;
begin
  UiHand := False;
  if not UiEnabled then
  begin
    UiPressed := False; UiReleased := False; UiDown := False;
    UiMouse := Vec2(-1000, -1000);
    Exit;
  end;
  m := GetMousePosition;
  UiMouse := Vec2((m.x - OffX) / Zoom, (m.y - OffY) / Zoom);
  UiPressed := IsMouseButtonPressed(MOUSE_BUTTON_LEFT);
  UiReleased := IsMouseButtonReleased(MOUSE_BUTTON_LEFT);
  UiDown := IsMouseButtonDown(MOUSE_BUTTON_LEFT);
  if UiPressed then UiPressPos := UiMouse;
end;

procedure UiEndFrame;
begin
  if not UiEnabled then Exit;
  if UiHand then SetMouseCursor(MOUSE_CURSOR_POINTING_HAND)
  else SetMouseCursor(MOUSE_CURSOR_DEFAULT);
end;

function Hover(const R: TRectangle; Layer: Integer): Boolean;
begin
  Result := (Layer >= UiModalLayer) and InRect(UiMouse, R);
end;

function Clicked(const R: TRectangle; Layer: Integer): Boolean;
begin
  Result := UiReleased and Hover(R, Layer) and InRect(UiPressPos, R);
end;

function Button(const R: TRectangle; const Caption: string; Style: TButtonStyle;
  Enabled: Boolean; Layer: Integer): Boolean;
var
  fill, rim, txt: TColor;
  h, down: Boolean;
begin
  h := Enabled and Hover(R, Layer);
  down := h and UiDown and InRect(UiPressPos, R);
  case Style of
    bsPrimary: begin fill := C_ACCENT_DIM; rim := C_ACCENT; txt := C_TEXT; end;
    bsDanger: begin fill := ColorRGBA(70, 22, 26, 255); rim := C_CRIT; txt := C_TEXT; end;
    bsGhost: begin fill := Fade(C_PANEL, 0); rim := C_RIM; txt := C_TEXT2; end;
  else
    begin fill := C_PANEL_HI; rim := C_RIM; txt := C_TEXT; end;
  end;
  if not Enabled then
  begin
    fill := Fade(C_PANEL, 160); rim := Fade(C_RIM, 120); txt := C_MUTED;
  end
  else if down then fill := Mix(fill, C_BG, 0.35)
  else if h then begin fill := Mix(fill, C_ACCENT, 0.18); UiHand := True; end;
  DrawRectangleRounded(R, 0.25, 6, rim);
  DrawRectangleRounded(Inset(R, 1.5), 0.25, 6, fill);
  TxtIn(FontBold, Caption, R, 15, txt, haCenter);
  Result := Enabled and Clicked(R, Layer);
end;

function Tab(const R: TRectangle; const Caption, Hint: string; Active: Boolean;
  Badge: Integer; const BadgeColor: TColor): Boolean;
var
  h: Boolean;
  bw: Single;
  b: TRectangle;
  s: string;
begin
  h := Hover(R);
  if h then UiHand := True;
  if Active then
    DrawRectangleRounded(R, 0.25, 6, C_ACCENT_DIM)
  else if h then
    DrawRectangleRounded(R, 0.25, 6, Fade(C_ACCENT_DIM, 120));
  if Active then
    DrawRectangle(Round(R.x + 12), Round(R.y + R.height - 3), Round(R.width - 24), 3, C_ACCENT);
  TxtIn(FontBold, Caption, Rect(R.x, R.y - 6, R.width, R.height), 17, C_TEXT, haCenter);
  TxtIn(FontUI, Hint, Rect(R.x, R.y + 13, R.width, R.height), 11, C_MUTED, haCenter);
  if Badge > 0 then
  begin
    s := IntToStr(Badge);
    bw := TextWidth(FontBold, s, 13) + 12;
    b := Rect(R.x + R.width - bw - 6, R.y + 4, bw, 20);
    DrawRectangleRounded(b, 1, 8, BadgeColor);
    TxtIn(FontBold, s, b, 13, C_BG, haCenter);
  end;
  Result := Clicked(R);
end;

end.
