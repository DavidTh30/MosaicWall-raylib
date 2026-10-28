unit uMosaicTypes;

{ Shared data types for the Mosaic Wallpaper (see SPEC_MosaicWallpaper.md §5.1). }

{$mode objfpc}{$H+}

interface

uses
  raylib;

type
  TTileKind = (tkBase, tkAccent);   // tkBase = blends into the background, tkAccent = vivid, outlined

  TTile = record
    cx, cy     : Single;    // centre (px)
    w, h       : Single;
    roundness  : Single;    // 0..1
    color      : TColor;
    color2     : TColor;    // alternate colour for gradient scroll
    kind       : TTileKind;
    phase      : Single;    // animation phase (radians)
    bridgeTo   : Integer;   // index of partner tile drawn together (-1 = none)
    isMember   : Boolean;   // true when this tile is the partner side of a bridge (drawn by its owner)
    hasGlint   : Boolean;
    glintAngle : Single;    // radians
    glintLen   : Single;    // fraction of w
    hasGlow    : Boolean;
  end;
  TTileArray = array of TTile;

  TMosaic = record
    Width, Height : Integer;
    Cell          : Single;
    Holes         : TTileArray;   // dark shading inside gaps
    Base          : TTileArray;   // background blobs
    Accent        : TTileArray;   // coloured tiles, row order (top to bottom)
  end;

  TMosaicConfig = record
    Seed          : LongWord;
    CellRatio     : Single;     // cell = width * ratio
    JitterPos     : Single;
    HoleChance    : Single;
    BridgeChance  : Single;
    Animate       : Boolean;
    GradientScroll: Boolean;
    GlowMode      : Integer;    // 0=off 1=gradient circle 2=gradient circle + downsampled RT
    Vignette      : Single;     // 0..1
    ZoneNoise     : Single;
    Dim           : Boolean;    // darken for use behind UI text
    Motion        : Single;     // animation strength: 0 = still, 1 = default, up to MOTION_MAX
  end;

const
  CELL_RATIO_MIN = 0.04;
  CELL_RATIO_MAX = 0.12;
  MOTION_MAX     = 3.0;

function DefaultMosaicConfig: TMosaicConfig;

implementation

function DefaultMosaicConfig: TMosaicConfig;
begin
  Result.Seed           := 653;
  Result.CellRatio      := 0.076;
  Result.JitterPos      := 0.22;
  Result.HoleChance     := 0.15;
  Result.BridgeChance   := 0.30;
  Result.Animate        := True;
  Result.GradientScroll := False;
  Result.GlowMode       := 1;
  Result.Vignette       := 0.12;
  Result.ZoneNoise      := 0.08;
  Result.Dim            := False;
  Result.Motion         := 1.0;
end;

end.
