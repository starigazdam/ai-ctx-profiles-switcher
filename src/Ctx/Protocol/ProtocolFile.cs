using System.Text;

namespace Ctx.Protocol;

// Byte-exact file I/O for the protocol: UTF-8 without BOM, LF only, NUL
// forbidden. The response is written to response.tmp and then atomically
// renamed to response, so a crash mid-write leaves no final response.
internal static class ProtocolFile
{
    public const string RequestMarker = "CTX-REQ 1";
    public const string ResponseMarker = "CTX-RES 1";

    public static List<KeyValuePair<string, string>> ReadRequest(string protocolDir)
    {
        var path = Path.Combine(protocolDir, "request");
        var bytes = File.ReadAllBytes(path);
        var text = DecodeStrict(bytes);

        if (!text.EndsWith('\n'))
        {
            throw new ProtocolException("request must end with LF");
        }

        var lines = text.Split('\n');
        var last = lines.Length - 1; // trailing empty element produced by the final LF
        if (last < 1 || lines[0] != RequestMarker)
        {
            throw new ProtocolException($"request must start with \"{RequestMarker}\"");
        }

        var fields = new List<KeyValuePair<string, string>>();
        var sawEnd = false;
        for (var i = 1; i < last; i++)
        {
            var line = lines[i];
            if (line == "END")
            {
                sawEnd = true;
                if (i != last - 1)
                {
                    throw new ProtocolException("unexpected data after END");
                }

                break;
            }

            var separator = line.IndexOf(' ');
            if (separator < 0)
            {
                throw new ProtocolException("request field line is missing a value separator");
            }

            var name = line[..separator];
            var escaped = line[(separator + 1)..];
            if (!ProtocolCodec.IsRequestField(name))
            {
                throw new ProtocolException($"unknown request field \"{name}\"");
            }

            fields.Add(new KeyValuePair<string, string>(name, ProtocolCodec.Unescape(escaped)));
        }

        if (!sawEnd)
        {
            throw new ProtocolException("request is missing the END line");
        }

        return fields;
    }

    public static void WriteResponse(string protocolDir, IEnumerable<KeyValuePair<string, string>> fields)
    {
        var builder = new StringBuilder();
        foreach (var field in fields)
        {
            builder
                .Append("REC probe.")
                .Append(field.Key)
                .Append(' ')
                .Append(ProtocolCodec.Escape(field.Value))
                .Append('\n');
        }

        WriteResponseBody(protocolDir, builder.ToString());
    }

    // Writes a fully-formed response body (the lines between "CTX-RES 1" and
    // the trailing "EXIT 0"/"END"). Every line must already be escaped. The
    // atomic tmp+rename, the EXIT 0 terminator and END are shared with
    // WriteResponse so `protocol clear` does not reimplement them.
    public static void WriteResponseBody(string protocolDir, string body)
    {
        var builder = new StringBuilder();
        builder.Append(ResponseMarker).Append('\n');
        builder.Append(body);
        builder.Append("EXIT 0\n");
        builder.Append("END\n");

        var bytes = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(builder.ToString());
        var tempPath = Path.Combine(protocolDir, "response.tmp");
        var finalPath = Path.Combine(protocolDir, "response");
        File.WriteAllBytes(tempPath, bytes);
        File.Move(tempPath, finalPath, overwrite: true);
    }

    private static string DecodeStrict(byte[] bytes)
    {
        foreach (var b in bytes)
        {
            if (b == 0x00)
            {
                throw new ProtocolException("request contains a NUL byte");
            }

            if (b == 0x0D)
            {
                throw new ProtocolException("request must use LF line endings");
            }
        }

        var decoder = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
        var text = decoder.GetString(bytes);
        if (text.Length > 0 && text[0] == '\uFEFF')
        {
            throw new ProtocolException("request must not start with a UTF-8 BOM");
        }

        return text;
    }
}
