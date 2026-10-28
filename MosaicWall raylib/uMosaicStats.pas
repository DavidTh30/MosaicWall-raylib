unit uMosaicStats;

{ Frame-time history and event log for the developer status window.
  No raylib or LCL dependency, so it can be used from both sides. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

const
  STATS_CAP  = 600;   // ~10 s of history at 60 FPS
  EVENTS_CAP = 500;

type
  TFrameSummary = record
    Count: Integer;
    AvgMs, MinMs, MaxMs, P95Ms, P99Ms: Single;   // whole frame (incl. vsync wait)
    CpuAvgMs, CpuMaxMs: Single;                  // CPU time to build the frame (before swap)
    Fps: Single;                                 // 1000 / AvgMs
  end;

  TMosaicStats = class
  private
    FFrame, FCpu, FSwap, FOutside: array[0..STATS_CAP - 1] of Single;
    FHead, FCount: Integer;
    FEvents: TStringList;
    FEventsTotal: Int64;
  public
    TotalFrames: Int64;
    StartTime: TDateTime;
    constructor Create;
    destructor Destroy; override;
    procedure Push(FrameMs, CpuMs: Single; SwapMs: Single = 0; OutsideMs: Single = 0);
    procedure Reset;
    // i = 0 is the oldest sample still in the buffer
    procedure Get(i: Integer; out FrameMs, CpuMs: Single);
    function Summary: TFrameSummary;
    procedure AddEvent(const Msg: string);
    procedure SaveCsv(const FileName: string);
    property Count: Integer read FCount;
    property Events: TStringList read FEvents;
    // number of events ever added; Events holds the last Events.Count of them
    property EventsTotal: Int64 read FEventsTotal;
  end;

implementation

constructor TMosaicStats.Create;
begin
  inherited Create;
  FEvents := TStringList.Create;
  StartTime := Now;
end;

destructor TMosaicStats.Destroy;
begin
  FEvents.Free;
  inherited Destroy;
end;

procedure TMosaicStats.Push(FrameMs, CpuMs, SwapMs, OutsideMs: Single);
begin
  FFrame[FHead] := FrameMs;
  FCpu[FHead] := CpuMs;
  FSwap[FHead] := SwapMs;
  FOutside[FHead] := OutsideMs;
  FHead := (FHead + 1) mod STATS_CAP;
  if FCount < STATS_CAP then Inc(FCount);
  Inc(TotalFrames);
end;

procedure TMosaicStats.Reset;
begin
  FHead := 0;
  FCount := 0;
end;

procedure TMosaicStats.Get(i: Integer; out FrameMs, CpuMs: Single);
var
  k: Integer;
begin
  k := (FHead - FCount + i + STATS_CAP) mod STATS_CAP;
  FrameMs := FFrame[k];
  CpuMs := FCpu[k];
end;

function TMosaicStats.Summary: TFrameSummary;
var
  sorted: array of Single;
  i, j: Integer;
  f, c, sumF, sumC, tmp: Single;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Count := FCount;
  if FCount = 0 then Exit;
  SetLength(sorted, FCount);
  sumF := 0; sumC := 0;
  Result.MinMs := 1e9;
  for i := 0 to FCount - 1 do
  begin
    Get(i, f, c);
    sorted[i] := f;
    sumF := sumF + f;
    sumC := sumC + c;
    if f < Result.MinMs then Result.MinMs := f;
    if f > Result.MaxMs then Result.MaxMs := f;
    if c > Result.CpuMaxMs then Result.CpuMaxMs := c;
  end;
  // insertion sort: at most 600 values, called a few times per second
  for i := 1 to FCount - 1 do
  begin
    tmp := sorted[i];
    j := i - 1;
    while (j >= 0) and (sorted[j] > tmp) do
    begin
      sorted[j + 1] := sorted[j];
      Dec(j);
    end;
    sorted[j + 1] := tmp;
  end;
  Result.AvgMs := sumF / FCount;
  Result.CpuAvgMs := sumC / FCount;
  Result.P95Ms := sorted[Trunc((FCount - 1) * 0.95)];
  Result.P99Ms := sorted[Trunc((FCount - 1) * 0.99)];
  if Result.AvgMs > 0 then Result.Fps := 1000 / Result.AvgMs;
end;

procedure TMosaicStats.AddEvent(const Msg: string);
begin
  FEvents.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + Msg);
  Inc(FEventsTotal);
  while FEvents.Count > EVENTS_CAP do
    FEvents.Delete(0);
end;

procedure TMosaicStats.SaveCsv(const FileName: string);
var
  L: TStringList;
  i, k: Integer;
  f, c: Single;
  fs: TFormatSettings;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  L := TStringList.Create;
  try
    L.Add('sample,frame_ms,cpu_ms,swap_ms,outside_ms');
    for i := 0 to FCount - 1 do
    begin
      Get(i, f, c);
      k := (FHead - FCount + i + STATS_CAP) mod STATS_CAP;
      L.Add(Format('%d,%.3f,%.3f,%.3f,%.3f', [i, f, c, FSwap[k], FOutside[k]], fs));
    end;
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;
end;

end.
