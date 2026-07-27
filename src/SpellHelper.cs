// ExpressSpellHelper — мост к системной проверке орфографии Windows (Windows Spell Checking API).
// Это тот же движок и те же лексиконы Microsoft, которыми пользуются Word/Outlook/Edge,
// включая пользовательский словарь %APPDATA%\Microsoft\Spelling\<lang>\default.dic.
//
// Использование:
//   ExpressSpellHelper.exe langs
//   ExpressSpellHelper.exe suggest <lang> <word>
//   ExpressSpellHelper.exe check   <lang> <text>
//   ExpressSpellHelper.exe add     <lang> <word>
//   ExpressSpellHelper.exe server            (построчный JSON на stdin/stdout)
//   ExpressSpellHelper.exe pipe <name>       (построчный JSON через именованный канал —
//                                             позволяет клиенту делать синхронные запросы)
// Вывод: одна строка JSON в UTF-8.

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace ExpressSpellFix
{
    [ComImport, Guid("B7C82D61-FBE8-4B47-9B27-6C0D2E0DE0A3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface ISpellingError
    {
        void get_StartIndex(out uint value);
        void get_Length(out uint value);
        void get_CorrectiveAction(out int value);
        void get_Replacement([MarshalAs(UnmanagedType.LPWStr)] out string value);
    }

    [ComImport, Guid("803E3BD4-2828-4410-8290-418D1D73C762"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IEnumSpellingError
    {
        [PreserveSig] int Next(out ISpellingError value);
    }

    [ComImport, Guid("B6FD0B71-E2BC-4653-8D05-F197E412770B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface ISpellChecker
    {
        void get_LanguageTag([MarshalAs(UnmanagedType.LPWStr)] out string tag);
        void Check([MarshalAs(UnmanagedType.LPWStr)] string text, out IEnumSpellingError errors);
        void Suggest([MarshalAs(UnmanagedType.LPWStr)] string word, out IEnumString suggestions);
        void Add([MarshalAs(UnmanagedType.LPWStr)] string word);
        void Ignore([MarshalAs(UnmanagedType.LPWStr)] string word);
        void AutoCorrect([MarshalAs(UnmanagedType.LPWStr)] string from, [MarshalAs(UnmanagedType.LPWStr)] string to);
    }

    [ComImport, Guid("8E018A9D-2415-4677-BF08-794EA61F94BB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface ISpellCheckerFactory
    {
        void get_SupportedLanguages(out IEnumString languages);
        void IsSupported([MarshalAs(UnmanagedType.LPWStr)] string tag, [MarshalAs(UnmanagedType.Bool)] out bool supported);
        void CreateSpellChecker([MarshalAs(UnmanagedType.LPWStr)] string tag, out ISpellChecker checker);
    }

    [ComImport, Guid("7AB36653-1796-484B-BDFA-E74F1DB7C1DC")]
    internal class SpellCheckerFactoryClass { }

    // Точечная правка app.asar: меняем только поле "main" в корневом package.json,
    // сохраняя длину файла в байтах (недостача добивается пробелами — JSON это допускает).
    // Заголовок архива при этом не меняется, переупаковка 571 МБ не нужна.
    internal static class Asar
    {
        internal class Entry
        {
            public long FileOffset;   // абсолютное смещение содержимого в файле
            public int Size;
            public string Content;
            public string Header;     // JSON-заголовок архива целиком
            public int EntryStart;    // границы записи файла внутри заголовка
            public int EntryLength;
        }

        // Записи в заголовке содержат вложенный объект integrity, поэтому границы
        // ищем по балансу фигурных скобок, а не регулярным выражением.
        private static int FindEntryEnd(string header, int braceStart)
        {
            int depth = 0;
            bool inString = false, escaped = false;
            for (int i = braceStart; i < header.Length; i++)
            {
                char c = header[i];
                if (escaped) { escaped = false; continue; }
                if (c == '\\') { escaped = true; continue; }
                if (c == '"') { inString = !inString; continue; }
                if (inString) continue;
                if (c == '{') depth++;
                else if (c == '}')
                {
                    depth--;
                    if (depth == 0) return i + 1;
                }
            }
            return -1;
        }

        internal static Entry FindRootManifest(string asarPath)
        {
            using (var stream = File.Open(asarPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                var reader = new BinaryReader(stream);
                reader.ReadUInt32();
                uint payloadSize = reader.ReadUInt32();
                reader.ReadUInt32();
                uint jsonSize = reader.ReadUInt32();
                string header = Encoding.UTF8.GetString(reader.ReadBytes((int)jsonSize));
                long dataOffset = ((8 + payloadSize + 3) / 4) * 4;

                var candidates = new List<Entry>();
                const string key = "\"package.json\":";
                int searchFrom = 0;
                while (true)
                {
                    int keyIndex = header.IndexOf(key, searchFrom, StringComparison.Ordinal);
                    if (keyIndex < 0) break;
                    searchFrom = keyIndex + key.Length;

                    int braceStart = header.IndexOf('{', keyIndex + key.Length);
                    if (braceStart < 0) break;
                    int entryEnd = FindEntryEnd(header, braceStart);
                    if (entryEnd < 0) break;

                    string body = header.Substring(braceStart, entryEnd - braceStart);
                    var sizeMatch = System.Text.RegularExpressions.Regex.Match(body, "\"size\"\\s*:\\s*(\\d+)");
                    var offsetMatch = System.Text.RegularExpressions.Regex.Match(body, "\"offset\"\\s*:\\s*\"(\\d+)\"");
                    if (!sizeMatch.Success || !offsetMatch.Success) continue;
                    int size = int.Parse(sizeMatch.Groups[1].Value);
                    if (size < 200 || size > 262144) continue;

                    candidates.Add(new Entry
                    {
                        Size = size,
                        FileOffset = dataOffset + long.Parse(offsetMatch.Groups[1].Value),
                        Header = header,
                        EntryStart = braceStart,
                        EntryLength = entryEnd - braceStart
                    });
                }

                // Корневой манифест приложения крупнее манифестов зависимостей — проверяем сверху.
                candidates.Sort((a, b) => b.Size.CompareTo(a.Size));
                foreach (var candidate in candidates)
                {
                    stream.Position = candidate.FileOffset;
                    var buffer = new byte[candidate.Size];
                    int read = 0;
                    while (read < candidate.Size)
                    {
                        int chunk = stream.Read(buffer, read, candidate.Size - read);
                        if (chunk <= 0) break;
                        read += chunk;
                    }
                    string text = Encoding.UTF8.GetString(buffer, 0, read);
                    if (text.Contains("\"main\"") &&
                        (text.Contains("\"appDesktopId\"") ||
                         (text.Contains("\"productName\"") && text.Contains("\"electron"))))
                    {
                        candidate.Content = text;
                        return candidate;
                    }
                }
                throw new Exception("root package.json not found in " + asarPath);
            }
        }

        private static string Sha256Hex(byte[] data)
        {
            using (var sha = System.Security.Cryptography.SHA256.Create())
            {
                var hash = sha.ComputeHash(data);
                var sb = new StringBuilder(hash.Length * 2);
                foreach (var b in hash) sb.Append(b.ToString("x2"));
                return sb.ToString();
            }
        }

        internal static string GetMain(string manifest)
        {
            var match = System.Text.RegularExpressions.Regex.Match(manifest, "\"main\"\\s*:\\s*\"([^\"]*)\"");
            return match.Success ? match.Groups[1].Value : "";
        }

        internal static string SetMain(string asarPath, string newMain)
        {
            var entry = FindRootManifest(asarPath);
            string currentMain = GetMain(entry.Content);
            if (currentMain.Length == 0) return "{\"ok\":false,\"error\":\"main field not found\"}";
            if (currentMain == newMain)
                return "{\"ok\":true,\"changed\":false,\"main\":" + Json(currentMain) + "}";

            // Хвостовые пробелы — это padding от прошлой правки: их нужно захватить,
            // иначе вернуть длинное исходное значение будет некуда.
            var match = System.Text.RegularExpressions.Regex.Match(entry.Content, "\"main\"\\s*:\\s*\"([^\"]*)\"[ \\t]*");
            string oldFragment = match.Value;
            string newFragment = "\"main\": \"" + newMain + "\"";
            int spare = Encoding.UTF8.GetByteCount(oldFragment) - Encoding.UTF8.GetByteCount(newFragment);
            if (spare < 0)
                return "{\"ok\":false,\"error\":\"new main is longer than the original field\"}";
            newFragment += new string(' ', spare);

            string updated = entry.Content.Substring(0, match.Index) + newFragment +
                             entry.Content.Substring(match.Index + match.Length);
            var bytes = Encoding.UTF8.GetBytes(updated);
            if (bytes.Length != entry.Size)
                return "{\"ok\":false,\"error\":\"size mismatch: " + bytes.Length + " vs " + entry.Size + "\"}";

            // Заголовок asar хранит SHA256 файла (integrity.hash и blocks[]).
            // Хеши обновляем на месте — длина hex-строки не меняется, заголовок не сдвигается.
            string oldHash = Sha256Hex(Encoding.UTF8.GetBytes(entry.Content));
            string newHash = Sha256Hex(bytes);
            string fragment = entry.Header.Substring(entry.EntryStart, entry.EntryLength);
            bool integrityUpdated = fragment.Contains(oldHash);
            string newHeader = null;
            if (integrityUpdated)
            {
                string newFragmentHeader = fragment.Replace(oldHash, newHash);
                newHeader = entry.Header.Substring(0, entry.EntryStart) + newFragmentHeader +
                            entry.Header.Substring(entry.EntryStart + entry.EntryLength);
                if (Encoding.UTF8.GetByteCount(newHeader) != Encoding.UTF8.GetByteCount(entry.Header))
                    return "{\"ok\":false,\"error\":\"header length changed\"}";
            }

            using (var stream = File.Open(asarPath, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite))
            {
                if (newHeader != null)
                {
                    var headerBytes = Encoding.UTF8.GetBytes(newHeader);
                    stream.Position = 16;
                    stream.Write(headerBytes, 0, headerBytes.Length);
                }
                stream.Position = entry.FileOffset;
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush();
            }
            return "{\"ok\":true,\"changed\":true,\"previousMain\":" + Json(currentMain) +
                   ",\"main\":" + Json(newMain) + ",\"offset\":" + entry.FileOffset +
                   ",\"size\":" + entry.Size + ",\"integrityUpdated\":" +
                   (integrityUpdated ? "true" : "false") + "}";
        }

        private static string Json(string value)
        {
            return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }
    }

    internal static class Program
    {
        private static ISpellCheckerFactory _factory;
        private static readonly Dictionary<string, ISpellChecker> Checkers =
            new Dictionary<string, ISpellChecker>(StringComparer.OrdinalIgnoreCase);

        private static ISpellCheckerFactory Factory
        {
            get { return _factory ?? (_factory = (ISpellCheckerFactory)new SpellCheckerFactoryClass()); }
        }

        private static ISpellChecker GetChecker(string lang)
        {
            ISpellChecker checker;
            if (Checkers.TryGetValue(lang, out checker)) return checker;
            Factory.CreateSpellChecker(lang, out checker);
            Checkers[lang] = checker;
            return checker;
        }

        private static List<string> Drain(IEnumString enumerator)
        {
            var result = new List<string>();
            if (enumerator == null) return result;
            var one = new string[1];
            IntPtr fetched = Marshal.AllocCoTaskMem(IntPtr.Size);
            try
            {
                while (enumerator.Next(1, one, fetched) == 0 && one[0] != null)
                {
                    result.Add(one[0]);
                    one[0] = null;
                }
            }
            finally { Marshal.FreeCoTaskMem(fetched); }
            return result;
        }

        private static string JsonString(string s)
        {
            var sb = new StringBuilder("\"");
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20 || c > 0x7E) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            return sb.Append('"').ToString();
        }

        private static string JsonArray(IEnumerable<string> items)
        {
            var sb = new StringBuilder("[");
            bool first = true;
            foreach (var item in items)
            {
                if (!first) sb.Append(',');
                sb.Append(JsonString(item));
                first = false;
            }
            return sb.Append(']').ToString();
        }

        private static string Ok(string body) { return "{\"ok\":true," + body + "}"; }
        private static string Fail(string message) { return "{\"ok\":false,\"error\":" + JsonString(message) + "}"; }

        private static string Execute(string[] args)
        {
            if (args.Length == 0) return Fail("no command");
            string cmd = args[0].ToLowerInvariant();

            switch (cmd)
            {
                case "langs":
                {
                    IEnumString langs;
                    Factory.get_SupportedLanguages(out langs);
                    return Ok("\"languages\":" + JsonArray(Drain(langs)));
                }
                case "suggest":
                {
                    if (args.Length < 3) return Fail("usage: suggest <lang> <word>");
                    IEnumString suggestions;
                    GetChecker(args[1]).Suggest(args[2], out suggestions);
                    return Ok("\"suggestions\":" + JsonArray(Drain(suggestions)));
                }
                case "check":
                {
                    if (args.Length < 3) return Fail("usage: check <lang> <text>");
                    IEnumSpellingError errors;
                    GetChecker(args[1]).Check(args[2], out errors);
                    var words = new List<string>();
                    ISpellingError error;
                    while (errors.Next(out error) == 0 && error != null)
                    {
                        uint start, length;
                        error.get_StartIndex(out start);
                        error.get_Length(out length);
                        words.Add(args[2].Substring((int)start, (int)length));
                        error = null;
                    }
                    return Ok("\"misspelled\":" + JsonArray(words));
                }
                case "add":
                {
                    if (args.Length < 3) return Fail("usage: add <lang> <word>");
                    GetChecker(args[1]).Add(args[2]);
                    return Ok("\"added\":" + JsonString(args[2]));
                }
                case "asar-info":
                {
                    if (args.Length < 2) return Fail("usage: asar-info <app.asar>");
                    var entry = Asar.FindRootManifest(args[1]);
                    return Ok("\"offset\":" + entry.FileOffset + ",\"size\":" + entry.Size +
                              ",\"main\":" + JsonString(Asar.GetMain(entry.Content)));
                }
                case "asar-set-main":
                {
                    if (args.Length < 3) return Fail("usage: asar-set-main <app.asar> <newMain>");
                    return Asar.SetMain(args[1], args[2]);
                }
                default:
                    return Fail("unknown command: " + cmd);
            }
        }

        // Резидентный сервер на именованном канале. Клиент шлёт строку "cmd\targ1\targ2\n"
        // и синхронно читает строку-ответ. Процесс живёт, пока жив родитель.
        private static void RunPipeServer(string pipeName)
        {
            int parentPid = -1;
            var parentArg = Environment.GetEnvironmentVariable("EXPRESS_SPELLFIX_PARENT");
            if (!string.IsNullOrEmpty(parentArg)) int.TryParse(parentArg, out parentPid);

            if (parentPid > 0)
            {
                var watchdog = new System.Threading.Timer(_ =>
                {
                    try { System.Diagnostics.Process.GetProcessById(parentPid); }
                    catch { Environment.Exit(0); }
                }, null, 10000, 10000);
                GC.KeepAlive(watchdog);
            }

            while (true)
            {
                using (var pipe = new System.IO.Pipes.NamedPipeServerStream(
                    pipeName, System.IO.Pipes.PipeDirection.InOut, 1,
                    System.IO.Pipes.PipeTransmissionMode.Byte, System.IO.Pipes.PipeOptions.None, 4096, 4096))
                {
                    pipe.WaitForConnection();
                    var encoding = new UTF8Encoding(false);
                    var reader = new StreamReader(pipe, encoding);
                    var writer = new StreamWriter(pipe, encoding) { AutoFlush = true };
                    try
                    {
                        string line;
                        while ((line = reader.ReadLine()) != null)
                        {
                            if (line.Length == 0) continue;
                            string reply;
                            try { reply = Execute(line.Split('\t')); }
                            catch (Exception ex) { reply = Fail(ex.Message); }
                            writer.WriteLine(reply);
                        }
                    }
                    catch (IOException) { /* клиент отключился — ждём следующего */ }
                }
            }
        }

        [STAThread]
        private static int Main(string[] args)
        {
            var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false));
            stdout.AutoFlush = true;
            Console.SetOut(stdout);

            try
            {
                if (args.Length > 1 && args[0].Equals("pipe", StringComparison.OrdinalIgnoreCase))
                {
                    RunPipeServer(args[1]);
                    return 0;
                }

                if (args.Length > 0 && args[0].Equals("server", StringComparison.OrdinalIgnoreCase))
                {
                    // Резидентный режим: одна команда на строку, аргументы разделены табом.
                    var stdin = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
                    string line;
                    while ((line = stdin.ReadLine()) != null)
                    {
                        if (line.Length == 0) continue;
                        string reply;
                        try { reply = Execute(line.Split('\t')); }
                        catch (Exception ex) { reply = Fail(ex.Message); }
                        Console.WriteLine(reply);
                    }
                    return 0;
                }

                Console.WriteLine(Execute(args));
                return 0;
            }
            catch (Exception ex)
            {
                Console.WriteLine(Fail(ex.Message));
                return 1;
            }
        }
    }
}
