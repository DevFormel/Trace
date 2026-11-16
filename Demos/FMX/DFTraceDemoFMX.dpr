// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

program DFTraceDemoFMX;

uses
  System.StartUpCopy,
  FMX.Forms,
  uMainFormFMX in 'uMainFormFMX.pas' {Form1};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TFormMainFMX, FormMainFMX);
  Application.Run;
end.
