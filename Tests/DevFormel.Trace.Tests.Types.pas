// DevFormel Trace, https://devformel.com/trace/
// Copyright (c) 2026 Dennis Powering.
// SPDX-License-Identifier: MPL-2.0
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

unit DevFormel.Trace.Tests.Types;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TKeyValuePairTests = class
  public
    [Test]
    procedure Text_IsWrittenAsJSONString;

    // Also checks that an integer literal picks the Int64 overload and not Double
    [Test]
    procedure IntegerLiteral_IsWrittenAsJSONNumber;

    [Test]
    procedure Float_UsesPeriodWhateverTheLocale;

    [Test]
    procedure Boolean_IsWrittenAsJSONBoolean;

    [Test]
    procedure NaN_IsStoredAsText;

    [Test]
    procedure ValueChangedAfterCreate_IsWrittenAsJSONString;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  System.Math,
  DevFormel.Trace.Types;

function ToJSONText(const APair: TDFKeyValuePair): string;
var
  JSONValue: TJSONValue;
begin
  JSONValue := APair.ToJSONValue;
  try
    Result := JSONValue.ToJSON;
  finally
    JSONValue.Free;
  end;
end;

procedure TKeyValuePairTests.Text_IsWrittenAsJSONString;
var
  Pair: TDFKeyValuePair;
begin
  Pair := TDFKeyValuePair.Create('Table', 'Customers');
  Assert.IsTrue(Pair.Kind = TDFValueKind.Text, 'Kind');
  Assert.AreEqual('"Customers"', ToJSONText(Pair));
end;

procedure TKeyValuePairTests.IntegerLiteral_IsWrittenAsJSONNumber;
var
  Pair: TDFKeyValuePair;
begin
  Pair := TDFKeyValuePair.Create('RowsFetched', 1250);
  Assert.IsTrue(Pair.Kind = TDFValueKind.Integer, 'Kind');
  Assert.AreEqual('1250', Pair.Value);
  Assert.AreEqual('1250', ToJSONText(Pair));
end;

procedure TKeyValuePairTests.Float_UsesPeriodWhateverTheLocale;
var
  Saved: Char;
  Pair: TDFKeyValuePair;
begin
  // German locale writes 1,5; JSON and the text form must not
  Saved := FormatSettings.DecimalSeparator;
  FormatSettings.DecimalSeparator := ',';
  try
    Pair := TDFKeyValuePair.Create('Ratio', 1.5);
    Assert.IsTrue(Pair.Kind = TDFValueKind.Float, 'Kind');
    Assert.AreEqual('1.5', Pair.Value);
    Assert.AreEqual('1.5', ToJSONText(Pair));
  finally
    FormatSettings.DecimalSeparator := Saved;
  end;
end;

procedure TKeyValuePairTests.Boolean_IsWrittenAsJSONBoolean;
var
  Pair: TDFKeyValuePair;
begin
  Pair := TDFKeyValuePair.Create('Cached', False);
  Assert.IsTrue(Pair.Kind = TDFValueKind.Boolean, 'Kind');
  Assert.AreEqual('false', Pair.Value);
  Assert.AreEqual('false', ToJSONText(Pair));
end;

procedure TKeyValuePairTests.NaN_IsStoredAsText;
var
  Pair: TDFKeyValuePair;
begin
  Pair := TDFKeyValuePair.Create('Ratio', NaN);
  Assert.IsTrue(Pair.Kind = TDFValueKind.Text, 'Kind');
  Assert.StartsWith('"', ToJSONText(Pair));
end;

procedure TKeyValuePairTests.ValueChangedAfterCreate_IsWrittenAsJSONString;
var
  Pair: TDFKeyValuePair;
begin
  Pair := TDFKeyValuePair.Create('RowsFetched', 1250);
  Pair.Value := 'many';
  Assert.AreEqual('"many"', ToJSONText(Pair));
end;

initialization
  TDUnitX.RegisterTestFixture(TKeyValuePairTests);

end.
