// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Register;

interface

procedure Register;

implementation

uses
  System.Classes,
  DevFormel.Trace.Hub,
  DevFormel.Trace.Sinks.LogFile,
  DevFormel.Trace.Sinks.Memo,
  DevFormel.Trace.Sinks.Sentry,
  DevFormel.Trace.Sinks.Seq,
  DevFormel.Trace.Sinks.WinEvent;

const
  PALETTE_PAGE = 'DevFormel Trace';

procedure Register;
begin
  RegisterComponents(PALETTE_PAGE, [
    TDFTraceHub,
    TDFFileSink,
    TDFMemoSink,
    TDFSentrySink,
    TDFSeqSink,
    TDFWinEventSink
  ]);
end;

end.
