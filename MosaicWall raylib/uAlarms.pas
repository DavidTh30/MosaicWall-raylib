unit uAlarms;

{ Alarm list for the factory HMI, modelled on ISA-18.2 states:
    Active + Unacknowledged  -> operator must see it (blinks)
    Active + Acknowledged    -> still a problem, operator knows
    Cleared + Unacknowledged -> condition gone, but nobody saw it yet
    Cleared                  -> history only
  An alarm is identified by its tag; raising a tag that is already active does nothing. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TAlarmPriority = (apCritical, apHigh, apMedium);
  TAlarmState = (asActiveUnack, asActiveAck, asClearedUnack, asCleared);

  TAlarm = record
    Id: Integer;
    Tag: string;          // e.g. ST30.TEMP_HI
    Station: string;      // e.g. ST30
    Text: string;
    Priority: TAlarmPriority;
    State: TAlarmState;
    RaisedAt, AckAt, ClearedAt: TDateTime;
  end;

  TAlarmManager = class
  private
    FAll: array of TAlarm;   // every alarm ever raised, oldest first
    FCount: Integer;
    FNextId: Integer;
    function FindOpen(const Tag: string): Integer;
  public
    // At = process time of the event (the plant clock, so simulated runs get correct times)
    procedure RaiseAlarm(const Tag, Station, Text: string; Priority: TAlarmPriority; At: TDateTime);
    procedure ClearAlarm(const Tag: string; At: TDateTime);
    procedure Ack(Id: Integer);
    procedure AckAll;
    function IsOpen(const Tag: string): Boolean;
    // "open" = not fully cleared (shown in the active list)
    function OpenCount: Integer;
    function UnackCount: Integer;
    function OpenCountOf(P: TAlarmPriority): Integer;
    // highest priority, newest unacknowledged alarm; -1 if none
    function TopUnack: Integer;
    // most severe open alarm (acked or not); -1 if none
    function TopOpen: Integer;
    function Get(i: Integer): TAlarm;
    procedure SaveCsv(const FileName: string);
    property Count: Integer read FCount;
  end;

const
  PRIORITY_NAME: array[TAlarmPriority] of string = ('CRITICAL', 'HIGH', 'MEDIUM');
  STATE_NAME: array[TAlarmState] of string = ('ACTIVE', 'ACKED', 'RTN UNACK', 'CLEARED');

implementation

function TAlarmManager.FindOpen(const Tag: string): Integer;
var
  i: Integer;
begin
  for i := FCount - 1 downto 0 do
    if (FAll[i].Tag = Tag) and (FAll[i].State in [asActiveUnack, asActiveAck]) then
      Exit(i);
  Result := -1;
end;

procedure TAlarmManager.RaiseAlarm(const Tag, Station, Text: string; Priority: TAlarmPriority; At: TDateTime);
begin
  if FindOpen(Tag) >= 0 then Exit;
  if FCount >= Length(FAll) then
    SetLength(FAll, FCount * 2 + 64);
  Inc(FNextId);
  FAll[FCount].Id := FNextId;
  FAll[FCount].Tag := Tag;
  FAll[FCount].Station := Station;
  FAll[FCount].Text := Text;
  FAll[FCount].Priority := Priority;
  FAll[FCount].State := asActiveUnack;
  FAll[FCount].RaisedAt := At;
  FAll[FCount].AckAt := 0;
  FAll[FCount].ClearedAt := 0;
  Inc(FCount);
end;

procedure TAlarmManager.ClearAlarm(const Tag: string; At: TDateTime);
var
  i: Integer;
begin
  i := FindOpen(Tag);
  if i < 0 then Exit;
  FAll[i].ClearedAt := At;
  if FAll[i].State = asActiveUnack then
    FAll[i].State := asClearedUnack
  else
    FAll[i].State := asCleared;
end;

procedure TAlarmManager.Ack(Id: Integer);
var
  i: Integer;
begin
  for i := 0 to FCount - 1 do
    if FAll[i].Id = Id then
    begin
      case FAll[i].State of
        asActiveUnack: FAll[i].State := asActiveAck;
        asClearedUnack: FAll[i].State := asCleared;
      else
        Exit;
      end;
      FAll[i].AckAt := Now;
      Exit;
    end;
end;

procedure TAlarmManager.AckAll;
var
  i: Integer;
begin
  for i := 0 to FCount - 1 do
    if FAll[i].State in [asActiveUnack, asClearedUnack] then
      Ack(FAll[i].Id);
end;

function TAlarmManager.IsOpen(const Tag: string): Boolean;
begin
  Result := FindOpen(Tag) >= 0;
end;

function TAlarmManager.OpenCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FCount - 1 do
    if FAll[i].State <> asCleared then Inc(Result);
end;

function TAlarmManager.UnackCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FCount - 1 do
    if FAll[i].State in [asActiveUnack, asClearedUnack] then Inc(Result);
end;

function TAlarmManager.OpenCountOf(P: TAlarmPriority): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FCount - 1 do
    if (FAll[i].State <> asCleared) and (FAll[i].Priority = P) then Inc(Result);
end;

function TAlarmManager.TopUnack: Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := FCount - 1 downto 0 do
    if FAll[i].State in [asActiveUnack, asClearedUnack] then
      if (Result < 0) or (FAll[i].Priority < FAll[Result].Priority) then
        Result := i;
end;

function TAlarmManager.TopOpen: Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := FCount - 1 downto 0 do
    if FAll[i].State in [asActiveUnack, asActiveAck] then
      if (Result < 0) or (FAll[i].Priority < FAll[Result].Priority) then
        Result := i;
end;

function TAlarmManager.Get(i: Integer): TAlarm;
begin
  Result := FAll[i];
end;

procedure TAlarmManager.SaveCsv(const FileName: string);
var
  L: TStringList;
  i: Integer;

  function T(d: TDateTime): string;
  begin
    if d = 0 then Result := '' else Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', d);
  end;

begin
  L := TStringList.Create;
  try
    L.Add('id,raised,priority,station,tag,text,state,acked,cleared');
    for i := 0 to FCount - 1 do
      with FAll[i] do
        L.Add(Format('%d,%s,%s,%s,%s,"%s",%s,%s,%s',
          [Id, T(RaisedAt), PRIORITY_NAME[Priority], Station, Tag,
           StringReplace(Text, '"', '""', [rfReplaceAll]), STATE_NAME[State], T(AckAt), T(ClearedAt)]));
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;
end;

end.
