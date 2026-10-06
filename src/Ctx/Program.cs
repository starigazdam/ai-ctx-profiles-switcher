using System.Text;
using Ctx.Protocol;

namespace Ctx;

internal static class Program
{
    private const string SyntheticHome = "synthetic-home";
    private const string GlobalUser = "global-user";
    private const string EphemeralClean = "ephemeral-clean";

    private static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

        if (args.Length > 0 && args[0] == "protocol")
        {
            return RunProtocol(args);
        }

        if (args.Length == 0 || args[0] != "current")
        {
            return Fail(args.Length == 0
                ? "ctx: error: missing command"
                : $"ctx: error: unknown command \"{args[0]}\"");
        }

        string? recordedMode = null;
        for (var i = 1; i < args.Length; i++)
        {
            var arg = args[i];
            if (arg == "--recorded-mode")
            {
                if (recordedMode is not null)
                {
                    return Fail("ctx: error: duplicate --recorded-mode");
                }

                if (i + 1 >= args.Length)
                {
                    return Fail("ctx: error: --recorded-mode requires a value");
                }

                recordedMode = args[++i];
            }
            else
            {
                return Fail($"ctx: error: unexpected argument \"{arg}\"");
            }
        }

        if (recordedMode is not null &&
            recordedMode is not (SyntheticHome or GlobalUser or EphemeralClean))
        {
            return Fail($"ctx: error: invalid --recorded-mode \"{recordedMode}\" (allowed values: {SyntheticHome}, {GlobalUser}, {EphemeralClean})");
        }

        if (!TryGet("AI_CTX_PROFILES", out var profiles) || string.IsNullOrEmpty(profiles))
        {
            Console.Out.Write("No active AI context.\n");
            Console.Out.Write("Run \"ctx <profile> [profile...]\" to activate one.\n");
            return 0;
        }

        PrintStatus(profiles, recordedMode);
        return 0;
    }

    private static int RunProtocol(string[] args)
    {
        if (args.Length < 2)
        {
            return ProtocolFail("missing protocol subcommand");
        }

        var subcommand = args[1];
        if (subcommand != "probe" && subcommand != "clear")
        {
            return ProtocolFail($"unknown protocol subcommand \"{subcommand}\"");
        }

        string? protocolDir = null;
        for (var i = 2; i < args.Length; i++)
        {
            var arg = args[i];
            if (arg == "--protocol-dir")
            {
                if (protocolDir is not null)
                {
                    return ProtocolFail("duplicate --protocol-dir");
                }

                if (i + 1 >= args.Length)
                {
                    return ProtocolFail("--protocol-dir requires a value");
                }

                protocolDir = args[++i];
            }
            else
            {
                return ProtocolFail($"unexpected argument \"{arg}\"");
            }
        }

        if (protocolDir is null)
        {
            return ProtocolFail("--protocol-dir is required");
        }

        try
        {
            var fields = ProtocolFile.ReadRequest(protocolDir);
            if (subcommand == "probe")
            {
                ProtocolFile.WriteResponse(protocolDir, fields);
            }
            else
            {
                ProtocolFile.WriteResponseBody(protocolDir, BuildClearResponse(fields));
            }

            return 0;
        }
        catch (ProtocolException ex)
        {
            return ProtocolFail(ex.Message);
        }
        catch (Exception ex)
        {
            return ProtocolFail(ex.Message);
        }
    }

    // `protocol clear` decision table: the non-`--all` ctx clear mutation
    // surface. It must match _ctx_clear / Clear-CtxContext byte-for-byte: the
    // engine only decides which allowlisted variables to unset and which flat
    // outcome records to emit; the shell prints the human-readable text.
    private static string BuildClearResponse(List<KeyValuePair<string, string>> fields)
    {
        var mode = GetField(fields, "active.mode");
        var activeHomeValue = GetField(fields, "active.home_value");
        var liveHomeWasSet = GetField(fields, "live.home_was_set") == "1";
        var liveHomeValue = GetField(fields, "live.home_value");

        var skillsOwned = GetField(fields, "skills.owned") == "1";
        var skillsWasSet = GetField(fields, "skills.was_set") == "1";
        var skillsValue = GetField(fields, "skills.value");
        var liveSkillsWasSet = GetField(fields, "live.skills_was_set") == "1";
        var liveSkillsValue = GetField(fields, "live.skills_value");

        var builder = new StringBuilder();
        builder.Append("UNSET AI_CTX_PROFILES\n");
        builder.Append("UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS\n");

        if (mode == SyntheticHome)
        {
            builder.Append("UNSET COPILOT_HOME\n");
        }
        else if (mode == EphemeralClean)
        {
            if (liveHomeWasSet && liveHomeValue == activeHomeValue)
            {
                builder.Append("UNSET COPILOT_HOME\n");
            }

            if (activeHomeValue.Length > 0)
            {
                AppendRecord(builder, "outcome.retained_ephemeral_home", activeHomeValue);
            }

            if (liveHomeWasSet && liveHomeValue != activeHomeValue)
            {
                AppendRecord(builder, "outcome.warn_home_changed", liveHomeValue);
            }
        }
        else if (mode == GlobalUser)
        {
            // Mode B never touches COPILOT_HOME.
        }
        else if (mode.Length == 0 && liveHomeWasSet)
        {
            // No matching activation record: COPILOT_HOME is unowned.
            AppendRecord(builder, "outcome.warn_unowned_home", liveHomeValue);
        }

        if (skillsOwned && skillsWasSet && liveSkillsWasSet && liveSkillsValue == skillsValue)
        {
            builder.Append("UNSET COPILOT_SKILLS_DIRS\n");
        }

        return builder.ToString();
    }

    private static void AppendRecord(StringBuilder builder, string name, string value)
    {
        if (!ProtocolCodec.IsClearOutcomeField(name))
        {
            throw new ProtocolException($"response record \"{name}\" is not allowlisted");
        }

        builder
            .Append("REC ")
            .Append(name)
            .Append(' ')
            .Append(ProtocolCodec.Escape(value))
            .Append('\n');
    }

    private static string GetField(List<KeyValuePair<string, string>> fields, string name)
    {
        for (var i = fields.Count - 1; i >= 0; i--)
        {
            if (fields[i].Key == name)
            {
                return fields[i].Value;
            }
        }

        return string.Empty;
    }

    private static int ProtocolFail(string message)
    {
        Console.Error.Write("ctx: error: protocol: ");
        Console.Error.Write(message);
        Console.Error.Write('\n');
        return 2;
    }

    private static int Fail(string message)
    {
        Console.Error.Write(message);
        Console.Error.Write("\n");
        Console.Error.Write("usage: ctx current [--recorded-mode synthetic-home|global-user|ephemeral-clean]\n");
        return 2;
    }

    private static void PrintStatus(string profiles, string? recordedMode)
    {
        var outw = Console.Out;

        var firstSeparator = profiles.IndexOf('+');
        string profile;
        string sharedCsv;
        if (firstSeparator < 0)
        {
            profile = profiles;
            sharedCsv = string.Empty;
        }
        else
        {
            profile = profiles[..firstSeparator];
            sharedCsv = profiles[(firstSeparator + 1)..].Replace("+", ", ");
        }

        outw.Write("\n[AI Context]\n\n");
        outw.Write($"Profile : {(profile.Length > 0 ? profile : "<none>")}\n");
        outw.Write($"Profiles: {(sharedCsv.Length > 0 ? sharedCsv : "<none>")}\n");
        outw.Write($"\nAI_CTX_PROFILES={(profiles.Length > 0 ? profiles : "<unset>")}\n");

        if (recordedMode is null)
        {
            outw.Write("Mode: <unknown>\n");
            if (TryGet("COPILOT_SKILLS_DIRS", out var unknownSkills))
            {
                outw.Write($"COPILOT_SKILLS_DIRS={unknownSkills} (unknown)\n");
            }

            if (TryGet("COPILOT_HOME", out var unknownHome))
            {
                outw.Write($"COPILOT_HOME={unknownHome} (unknown)\n");
            }
            else
            {
                outw.Write("COPILOT_HOME=<unset>\n");
            }
        }
        else
        {
            outw.Write($"Mode: {ModeLabel(recordedMode)}\n");
            if (recordedMode != SyntheticHome)
            {
                outw.Write($"COPILOT_SKILLS_DIRS={DisplayOrUnset("COPILOT_SKILLS_DIRS")}\n");
            }

            outw.Write($"COPILOT_HOME={DisplayOrUnset("COPILOT_HOME")}\n");
        }

        outw.Write("\nCOPILOT_CUSTOM_INSTRUCTIONS_DIRS=\n");
        if (!TryGet("COPILOT_CUSTOM_INSTRUCTIONS_DIRS", out var custom))
        {
            outw.Write("<unset>\n");
        }
        else if (custom.Length == 0)
        {
            outw.Write("<present-empty>\n");
        }
        else
        {
            foreach (var entry in custom.Split(','))
            {
                outw.Write(entry);
                outw.Write('\n');
            }
        }
    }

    private static string ModeLabel(string mode) => mode switch
    {
        SyntheticHome => "A \u2014 synthetic-home",
        GlobalUser => "B \u2014 global-user",
        EphemeralClean => "C \u2014 ephemeral-clean",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };

    private static string DisplayOrUnset(string name)
        => TryGet(name, out var value) && value.Length > 0 ? value : "<unset>";

    private static bool TryGet(string name, out string value)
    {
        var variables = Environment.GetEnvironmentVariables(EnvironmentVariableTarget.Process);
        if (variables.Contains(name))
        {
            value = variables[name] as string ?? string.Empty;
            return true;
        }

        value = string.Empty;
        return false;
    }
}
