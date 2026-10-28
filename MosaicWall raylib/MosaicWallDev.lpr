program MosaicWallDev;

{ MosaicWall animation + developer status window (LCL).
  The mosaic runs in a raylib window; DevForm shows live status, controls and exports. }

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, uDevForm;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Title := 'MosaicWall Dev';
  Application.Initialize;
  Application.CreateForm(TDevForm, DevForm);
  DevForm.Show;
  DevForm.StartEngine;
  Application.Run;
end.
