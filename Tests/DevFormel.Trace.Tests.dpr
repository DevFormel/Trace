// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

program DevFormel.Trace.Tests;

{$IFNDEF TESTINSIGHT}
{$APPTYPE CONSOLE}
{$ENDIF}
{$STRONGLINKTYPES ON}
uses
  System.SysUtils,
  {$IFDEF TESTINSIGHT}
  TestInsight.DUnitX,
  {$ELSE}
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  {$ENDIF }
  DUnitX.TestFramework,
  DevFormel.Trace.Tests.Sanitizer in 'DevFormel.Trace.Tests.Sanitizer.pas',
  DevFormel.Trace.Tests.Types in 'DevFormel.Trace.Tests.Types.pas',
  DevFormel.Trace.Tests.Hub in 'DevFormel.Trace.Tests.Hub.pas',
  DevFormel.Trace.Tests.Queue in 'DevFormel.Trace.Tests.Queue.pas',
  DevFormel.Trace.Tests.Sinks in 'DevFormel.Trace.Tests.Sinks.pas';

{ keep comment here to protect the following conditional from being removed by the IDE when adding a unit }
{$IFNDEF TESTINSIGHT}
var
  runner: ITestRunner;
  results: IRunResults;
  logger: ITestLogger;
  nunitLogger : ITestLogger;
{$ENDIF}
begin
  // Delphi's built-in memory manager reports leaks when the test run ends
  ReportMemoryLeaksOnShutdown := True;
{$IFDEF TESTINSIGHT}
  TestInsight.DUnitX.RunRegisteredTests;
{$ELSE}
  try
    //Check command line options, will exit if invalid
    TDUnitX.CheckCommandLine;
    //Create the test runner
    runner := TDUnitX.CreateRunner;
    //Tell the runner to use RTTI to find Fixtures
    runner.UseRTTI := True;
    //When true, Assertions must be made during tests;
    runner.FailsOnNoAsserts := False;

    //tell the runner how we will log things
    //Log to the console window if desired
    if TDUnitX.Options.ConsoleMode <> TDunitXConsoleMode.Off then
    begin
      logger := TDUnitXConsoleLogger.Create(TDUnitX.Options.ConsoleMode = TDunitXConsoleMode.Quiet);
      runner.AddLogger(logger);
    end;
    //Generate an NUnit compatible XML File
    nunitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
    runner.AddLogger(nunitLogger);

    //Run tests
    results := runner.Execute;
    if not results.AllPassed then
      System.ExitCode := EXIT_ERRORS;

  except
    on E: Exception do
      System.Writeln(E.ClassName, ': ', E.Message);
  end;

  {$IFNDEF CI}
  // Always wait, also without debugger (Ctrl+Shift+F9) and after an exception, so the
  // results stay readable. Builds for automated runs define CI.
  System.Write('Done.. press <Enter> key to quit.');
  System.Readln;
  {$ENDIF}
{$ENDIF}
end.
