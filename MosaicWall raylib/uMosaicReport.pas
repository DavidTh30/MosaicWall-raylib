unit uMosaicReport;

{ Builds the developer status list from the engine and exports it as JSON / TXT.
  The status window shows exactly this list, so what you see is what gets exported. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, uMosaicEngine;

type
  TStatusItem = record
    Section, Key, Value: string;
  end;
  TStatusList = array of TStatusItem;

procedure CollectStatus(E: TMosaicEngine; out L: TStatusList);
procedure ExportStatusTxt(E: TMosaicEngine; const FileName: string);
procedure ExportStatusJson(E: TMosaicEngine; const FileName: string);

implementation

uses
  Classes, fpjson, uMosaicTypes, uMosaicStats, uSysInfo;

var
  FS: TFormatSettings;

procedure CollectStatus(E: TMosaicEngine; out L: TStatusList);
var
  n: Integer;
  sec: string;
  S: TFrameSummary;
  pm: TProcessMem;
  up: Double;

  procedure Add(const K, V: string);
  begin
    if n >= Length(L) then SetLength(L, n + 32);
    L[n].Section := sec;
    L[n].Key := K;
    L[n].Value := V;
    Inc(n);
  end;

  function OnOff(b: Boolean): string;
  begin
    if b then Result := 'on' else Result := 'off';
  end;

begin
  n := 0;
  L := nil;
  S := E.Stats.Summary;
  pm := GetProcessMem;
  up := (Now - E.Stats.StartTime) * 86400;

  sec := 'Performance';
  Add('FPS (avg of history)', Format('%.1f', [S.Fps], FS));
  Add('Frame ms avg / p95 / p99', Format('%.2f / %.2f / %.2f', [S.AvgMs, S.P95Ms, S.P99Ms], FS));
  Add('Frame ms min / max', Format('%.2f / %.2f', [S.MinMs, S.MaxMs], FS));
  Add('CPU build ms avg / max', Format('%.2f / %.2f', [S.CpuAvgMs, S.CpuMaxMs], FS));
  Add('Frames in history', IntToStr(S.Count));
  Add('Frames total', IntToStr(E.Stats.TotalFrames));
  Add('Target', '60 FPS, vsync');
  if E.UiRefreshMs > 0 then
    Add('Status window refresh', Format('%.2f ms every 250 ms', [E.UiRefreshMs], FS));
  Add('Uptime', Format('%.0f s', [up], FS));

  sec := 'Scene';
  Add('State', E.StateText);
  Add('Seed', IntToStr(E.Cfg.Seed));
  Add('Window', Format('%d x %d', [E.Width, E.Height]));
  Add('Cell', Format('%.0f px (ratio %.3f)', [E.Mosaic.Cell, E.Cfg.CellRatio], FS));
  Add('Grid', Format('%d x %d cells', [E.GridCols, E.GridRows]));
  Add('Base blobs', IntToStr(Length(E.Mosaic.Base)));
  Add('Gap holes', IntToStr(Length(E.Mosaic.Holes)));
  Add('Accent tiles', Format('%d (vivid %d, muted %d)',
    [Length(E.Mosaic.Accent), E.VividCount, Length(E.Mosaic.Accent) - E.VividCount]));
  Add('Accent per zone Z0/Z1/Z2/Z3', Format('%d / %d / %d / %d',
    [E.ZoneCounts[0], E.ZoneCounts[1], E.ZoneCounts[2], E.ZoneCounts[3]]));
  Add('Bridges / glow / glint', Format('%d / %d / %d', [E.BridgeCount, E.GlowCount, E.GlintCount]));
  Add('Draw calls per frame', IntToStr(E.DrawCalls));
  Add('Generate time', Format('%.2f ms', [E.GenMs], FS));
  Add('Animation time', Format('%.2f s', [E.AnimTime], FS));

  sec := 'Config';
  Add('Glow mode', IntToStr(E.Cfg.GlowMode));
  Add('Animate', OnOff(not E.Paused));
  Add('Motion', Format('%.0f %%', [E.Cfg.Motion * 100], FS));
  Add('Gradient scroll', OnOff(E.Cfg.GradientScroll));
  Add('Vignette', Format('%.2f', [E.Cfg.Vignette], FS));
  Add('Dim', OnOff(E.Cfg.Dim));
  Add('HUD overlay', OnOff(E.ShowHud));
  Add('Jitter / hole / bridge', Format('%.2f / %.2f / %.2f',
    [E.Cfg.JitterPos, E.Cfg.HoleChance, E.Cfg.BridgeChance], FS));
  Add('Zone noise', Format('%.2f', [E.Cfg.ZoneNoise], FS));

  sec := 'Resources';
  Add('GPU textures (est.)', Format('%.1f MB', [E.GpuBytes / (1024 * 1024)], FS));
  Add('RAM working set', Format('%.1f MB (peak %.1f)', [pm.WorkingSetMB, pm.PeakWorkingSetMB], FS));
  Add('RAM private', Format('%.1f MB', [pm.PrivateMB], FS));

  sec := 'System';
  Add('GPU', E.GLRenderer);
  Add('GPU vendor', E.GLVendor);
  Add('OpenGL', E.GLVersion);
  Add('raylib.dll', FileInfoText(ExtractFilePath(ParamStr(0)) + 'raylib.dll'));
  Add('OS', OSVersionText);
  Add('CPU threads', IntToStr(CpuCount));
  Add('Build', BuildInfoText);

  sec := 'Export';
  Add('Folder', E.ExportDir);
  if E.LastExport <> '' then Add('Last export', ExtractFileName(E.LastExport))
  else Add('Last export', '-');

  SetLength(L, n);
end;

procedure ExportStatusTxt(E: TMosaicEngine; const FileName: string);
var
  L: TStatusList;
  T: TStringList;
  i: Integer;
  sec: string;
begin
  CollectStatus(E, L);
  T := TStringList.Create;
  try
    T.Add('MosaicWall developer status report');
    T.Add('Generated ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    sec := '';
    for i := 0 to High(L) do
    begin
      if L[i].Section <> sec then
      begin
        sec := L[i].Section;
        T.Add('');
        T.Add('[' + sec + ']');
      end;
      T.Add(Format('  %-30s %s', [L[i].Key, L[i].Value]));
    end;
    T.Add('');
    T.Add('[Event log]');
    T.AddStrings(E.Stats.Events);
    ForceDirectories(ExtractFileDir(ExpandFileName(FileName)));
    T.SaveToFile(FileName);
  finally
    T.Free;
  end;
  E.LastExport := FileName;
  E.Log('exported ' + ExtractFileName(FileName));
end;

// config values are Singles; round so the JSON shows 0.068 instead of 0.0680000037
function R4(v: Single): Double;
begin
  Result := Round(v * 10000) / 10000;
end;

procedure ExportStatusJson(E: TMosaicEngine; const FileName: string);
var
  L: TStatusList;
  root, secObj, frames, cfg: TJSONObject;
  arrF, arrC, ev: TJSONArray;
  i: Integer;
  f, c: Single;
  T: TStringList;
begin
  CollectStatus(E, L);
  root := TJSONObject.Create;
  try
    root.Add('app', 'MosaicWall');
    root.Add('generated', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now));

    // raw config values (machine-readable, unlike the formatted status strings)
    cfg := TJSONObject.Create;
    cfg.Add('seed', Int64(E.Cfg.Seed));
    cfg.Add('cellRatio', R4(E.Cfg.CellRatio));
    cfg.Add('jitterPos', R4(E.Cfg.JitterPos));
    cfg.Add('holeChance', R4(E.Cfg.HoleChance));
    cfg.Add('bridgeChance', R4(E.Cfg.BridgeChance));
    cfg.Add('glowMode', E.Cfg.GlowMode);
    cfg.Add('vignette', R4(E.Cfg.Vignette));
    cfg.Add('zoneNoise', R4(E.Cfg.ZoneNoise));
    cfg.Add('motion', R4(E.Cfg.Motion));
    cfg.Add('gradientScroll', E.Cfg.GradientScroll);
    cfg.Add('dim', E.Cfg.Dim);
    cfg.Add('paused', E.Paused);
    cfg.Add('width', E.Width);
    cfg.Add('height', E.Height);
    root.Add('config', cfg);

    secObj := nil;
    for i := 0 to High(L) do
    begin
      if (secObj = nil) or (root.IndexOfName(L[i].Section) < 0) then
      begin
        secObj := TJSONObject.Create;
        root.Add(L[i].Section, secObj);
      end;
      secObj.Add(L[i].Key, L[i].Value);
    end;

    frames := TJSONObject.Create;
    arrF := TJSONArray.Create;
    arrC := TJSONArray.Create;
    for i := 0 to E.Stats.Count - 1 do
    begin
      E.Stats.Get(i, f, c);
      arrF.Add(Round(f * 1000) / 1000);
      arrC.Add(Round(c * 1000) / 1000);
    end;
    frames.Add('frameMs', arrF);
    frames.Add('cpuMs', arrC);
    root.Add('frameHistory', frames);

    ev := TJSONArray.Create;
    for i := 0 to E.Stats.Events.Count - 1 do
      ev.Add(E.Stats.Events[i]);
    root.Add('events', ev);

    T := TStringList.Create;
    try
      T.Text := root.FormatJSON;
      ForceDirectories(ExtractFileDir(ExpandFileName(FileName)));
      T.SaveToFile(FileName);
    finally
      T.Free;
    end;
  finally
    root.Free;
  end;
  E.LastExport := FileName;
  E.Log('exported ' + ExtractFileName(FileName));
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := ',';
end.
