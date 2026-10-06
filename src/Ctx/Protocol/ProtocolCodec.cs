using System.Text;

namespace Ctx.Protocol;

// The single shared encode/decode pair for the line-oriented shell<->engine
// protocol. Escaping: '\' -> "\\", LF -> "\n", CR -> "\r"; every other byte
// (space, comma, tab, full UTF-8) passes through literally and is never
// re-encoded. A backslash followed by anything else is a parse error.
internal static class ProtocolCodec
{
    public static readonly string[] RequestFields =
    {
        "active.mode",
        "active.context",
        "active.custom_dirs",
        "active.home_was_set",
        "active.home_value",
        "skills.owned",
        "skills.was_set",
        "skills.value",
        "autoload.dir",
        "autoload.home_override",
        "live.home_was_set",
        "live.home_value",
        "live.skills_was_set",
        "live.skills_value",
    };

    // Flat, non-namespaced REC allowlist for `protocol clear` outcomes. The
    // `protocol probe` subcommand keeps its own `probe.`-prefixed echo and is
    // deliberately not represented here.
    public static readonly string[] ClearOutcomeFields =
    {
        "outcome.warn_unowned_home",
        "outcome.warn_home_changed",
        "outcome.retained_ephemeral_home",
    };

    public static readonly string[] EnvNames =
    {
        "AI_CTX_PROFILES",
        "COPILOT_CUSTOM_INSTRUCTIONS_DIRS",
        "COPILOT_HOME",
        "COPILOT_SKILLS_DIRS",
    };

    public const string EnvNameAllowingEmpty = "COPILOT_CUSTOM_INSTRUCTIONS_DIRS";

    public static bool IsRequestField(string name) => Array.IndexOf(RequestFields, name) >= 0;

    public static bool IsClearOutcomeField(string name) => Array.IndexOf(ClearOutcomeFields, name) >= 0;

    public static bool IsEnvName(string name) => Array.IndexOf(EnvNames, name) >= 0;

    public static string Escape(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var c in value)
        {
            switch (c)
            {
                case '\\':
                    builder.Append("\\\\");
                    break;
                case '\n':
                    builder.Append("\\n");
                    break;
                case '\r':
                    builder.Append("\\r");
                    break;
                default:
                    builder.Append(c);
                    break;
            }
        }

        return builder.ToString();
    }

    public static string Unescape(string escaped)
    {
        var builder = new StringBuilder(escaped.Length);
        for (var i = 0; i < escaped.Length; i++)
        {
            var c = escaped[i];
            if (c != '\\')
            {
                builder.Append(c);
                continue;
            }

            if (i + 1 >= escaped.Length)
            {
                throw new ProtocolException("invalid trailing escape");
            }

            var next = escaped[++i];
            switch (next)
            {
                case '\\':
                    builder.Append('\\');
                    break;
                case 'n':
                    builder.Append('\n');
                    break;
                case 'r':
                    builder.Append('\r');
                    break;
                default:
                    throw new ProtocolException($"invalid escape sequence \"\\{next}\"");
            }
        }

        return builder.ToString();
    }
}

internal sealed class ProtocolException : Exception
{
    public ProtocolException(string message)
        : base(message)
    {
    }
}
