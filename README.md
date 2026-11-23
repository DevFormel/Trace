# DevFormel Trace

Trace is in beta. The API can still change before version 1.0.0.

Logging and error reporting for Delphi applications, VCL and FMX.

Your application passes events, exceptions and breadcrumbs to a hub. A background
thread hands them on to sinks: a log file, the Windows event log, a memo, a Seq
server or a Sentry server (GlitchTip works as well). Before an event reaches the
sinks, personal data and secrets are removed, such as e-mail addresses, IPv4
addresses and passwords written as `password=...`. Detection is based on patterns,
so there is no guarantee that all of them are removed: names of other people,
postal addresses or customer numbers in free text are not detected.

## Requirements

- Delphi 10.4.1 Sydney or later. Trace is developed with Delphi 13; older versions
  should work but have not been tested.
- Windows, 32 and 64 bit. Other platforms have not been tried.
- No libraries outside the Delphi RTL. The test project uses DUnitX, which comes
  with Delphi.

## Installation

1. Open `DevFormel.Trace.groupproj`.
2. Build `DevFormel.Trace` and install `DevFormel.Trace.Design`. The components
   then appear on the palette page "DevFormel Trace".
3. Add the `Source` folder to the search path of your project, or to the library
   path of each target platform under Tools > Options > Language > Delphi >
   Library. The demos and the test project already find it themselves.

## Example

```pascal
uses
  DevFormel.Trace.Types, DevFormel.Trace.Hub, DevFormel.Trace.Sinks.LogFile;

procedure TFormMain.FormCreate(Sender: TObject);
var
  Hub: TDFTraceHub;
  FileSink: TDFFileSink;
begin
  // Also reports unhandled exceptions
  Hub := TDFTraceHub.Create(Self);

  // Writes to %LOCALAPPDATA%\<exe name>\Logs\trace.log
  FileSink := TDFFileSink.Create(Self);
  FileSink.Hub := Hub;

  Hub.TrackEvent('Order saved', [TDFKeyValuePair.Create('OrderId', 4711)]);
end;
```

The same works without code: place a `TDFTraceHub` and a sink on a form and set
the `Hub` property of the sink.

For unit names and line numbers in stack traces, set the linker option "Map file"
to "Detailed" and ship the `.map` file next to the executable. The map file shows
the names of your units and methods to anyone who has it.

## Known issues

- In 32-bit programs, stack traces can be incomplete. The caller of an RTL
  routine such as `StrToInt` can be missing, and the stack trace of a hardware
  exception can end with the line where it occurred.
- The Windows event log rejects entries longer than 31,839 characters. Such an
  event is missing from the event log without notice. Long stack traces and many
  breadcrumbs make this more likely.
- A scope returned by `TrackScope` that lives longer than its hub accesses freed
  memory. Release all scopes before the hub.
- Sentry accepts tag values up to 200 characters, Trace passes on up to 8,000.
  What Sentry does with longer values has not been tested.
- The map file is loaded when the first stack trace is created, in the thread
  that asks for it. That first stack trace takes longer.
- A second instance of the program cannot write to the same log file.

## Documentation

https://docs.devformel.com

## License

Mozilla Public License 2.0, see [LICENSE](LICENSE).

## Contributing

Bug reports and suggestions are welcome as issues. Pull requests are not accepted
for now, so that all code stays under one copyright holder while the project is
young.

## Security

See [SECURITY.md](SECURITY.md).
