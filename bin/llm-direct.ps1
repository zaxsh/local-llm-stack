<#
.SYNOPSIS
    Build llama-direct.exe: one window that downloads, starts and opens a local model.

.DESCRIPTION
    Generates a small WinForms launcher with the model list and the measured flags compiled in,
    then compiles it with the .NET Framework compiler that ships with Windows. No runtime, no
    installer, no dependencies - a ~30 KB exe.

    It is written into Desktop\llama.cpp and copied to the Desktop itself. Run from either place:
    it finds the engine folder next to it, inside llama.cpp\, or at the known Desktop path.

    Buttons: Start model / Open web UI / Stop / Folder, plus Download (calls fetch\llm-fetch.ps1,
    which pulls the GGUF from Hugging Face with xet and drops it into models\ under the name the
    registry expects) and HF token (writes the token where the hf CLI reads it).

    Re-run this after changing the registry in llm-up.ps1 or the catalogue in models.manifest.json
    so the launcher's list, flags and download sources match.

.EXAMPLE
    .\llm-direct.ps1
#>
[CmdletBinding()]
param(
    [string]$Bundle = "$env:USERPROFILE\Desktop\Local-LLM-Project\llama.cpp",
    [string]$DesktopCopy = "$env:USERPROFILE\Desktop\Local-LLM-Project\llama-direct.exe"
)

$ErrorActionPreference = 'Stop'
$bin = $PSScriptRoot

# ---------------------------------------------------------------- model list
$up = Get-Content (Join-Path $bin 'llm-up.ps1') -Raw
$entries = [ordered]@{}
foreach ($m in [regex]::Matches($up, "(?m)^\s*(\w+)\s*=\s*@\{\s*File\s*=\s*'([^']+)';\s*Port\s*=\s*(\d+);\s*Alias\s*=\s*'([^']+)';\s*Ctx\s*=\s*(\d+);\s*CpuMoe\s*=\s*(\d+);\s*Threads\s*=\s*(\d+)(?:;\s*Note\s*=\s*'([^']*)')?")) {
    $entries[$m.Groups[1].Value] = @{
        File = $m.Groups[2].Value; Port = [int]$m.Groups[3].Value; Alias = $m.Groups[4].Value
        Ctx = $m.Groups[5].Value; CpuMoe = [int]$m.Groups[6].Value; Threads = $m.Groups[7].Value
        Note = $(if ($m.Groups[8].Success) { $m.Groups[8].Value } else { '' })
    }
}
if ($entries.Count -eq 0) { throw "could not read the registry from llm-up.ps1" }

# download sources come from the same manifest llm-fetch.ps1 uses
$catalog = @{}
$manifestPath = Join-Path $bin '..\models.manifest.json'
if (Test-Path $manifestPath) {
    foreach ($mm in (Get-Content $manifestPath -Raw | ConvertFrom-Json).models) { $catalog[$mm.key] = $mm }
}

$friendly = [ordered]@{
    gemma4 = @{ Title = 'Gemma 4 E4B';      Sub = 'fastest - 74 t/s at 131k context, native tool calls' }
    qwen36 = @{ Title = 'Qwen3.6 35B-A3B';  Sub = 'strongest - 34 t/s at 20k context, native tool calls' }
    flint  = @{ Title = 'flint 40B';        Sub = 'deep reasoning - 30 t/s at 49k context' }
    qwen3  = @{ Title = 'Qwen3 8B';         Sub = 'balanced - 59 t/s, thinks before answering' }
    coder  = @{ Title = 'Qwen2.5 Coder 7B'; Sub = 'code only - 50 t/s at 32k context, NO tool calls' }
    gptoss = @{ Title = 'gpt-oss 20B';      Sub = '31 t/s at 24k context, no working tool calls' }
    coder36 = @{ Title = 'Qwen3.6 27B-A3B Coder'; Sub = '44 t/s at 32k context - code, native tool calls' }
}

function CsLiteral([string]$s) {
    # verbatim string: only the quote needs doubling
    if ($null -eq $s) { $s = '' }
    return '@"' + $s.Replace('"', '""') + '"'
}

$cs = New-Object System.Collections.Generic.List[string]
foreach ($k in $entries.Keys) {
    $e = $entries[$k]
    $f = $friendly[$k]
    # A key that is not in the map above must still show a real name and a real description, taken
    # from the registry, instead of the bare key and a blank line.
    $title = if ($f) { $f.Title } else { $e.Alias }
    $sub = if ($f) { $f.Sub } elseif ($e.Note) { $e.Note } else { '' }
    $args = "-m `"models\$($e.File)`" --alias $($e.Alias) --host 127.0.0.1 --port $($e.Port) -c $($e.Ctx) --jinja --metrics --no-warmup -t $($e.Threads) -tb $($e.Threads) -ngl 99 -fa on -ctk f16 -ctv f16"
    # no quote-doubling here: CsLiteral() emits a verbatim @"..." string and doubles them itself.
    # Doing it in both places sent -m ""models\x.gguf"" to the engine.
    if ($e.CpuMoe -gt 0) { $args += " --n-cpu-moe $($e.CpuMoe)" }

    $cat = $catalog[$k]
    $repo = ''; $repoFile = ''; $size = '0'
    if ($cat) {
        $repo = $cat.repo; $repoFile = $cat.repoFile
        $size = if ($cat.sizeBytes) { [string]$cat.sizeBytes } else { '0' }
    }
    $cs.Add(("            Add(list, {0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}L);" -f `
        (CsLiteral $k), (CsLiteral $title), (CsLiteral $sub), $e.Port, (CsLiteral $args), `
        (CsLiteral $e.File), (CsLiteral $repo), (CsLiteral $repoFile), $size))
}
$modelBlock = ($cs -join "`r`n")

# Guard against the escaping bug that shipped once: quotes were doubled for a verbatim string and
# then doubled again, so the engine received -m ""models\x.gguf"" and silently misbehaved. Four
# consecutive quotes can only mean double escaping.
if ($modelBlock -match '""""') { throw "model arguments look double-escaped - check CsLiteral() against the -m line" }

# ---------------------------------------------------------------- source
# Single-quoted here-string: nothing in the C# is interpreted by PowerShell.
$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

class Model
{
    public string Key, Title, Sub, Args, File, Repo, RepoFile;
    public int Port;
    public long SizeBytes;
}

class App : Form
{
    List<Model> models = new List<Model>();
    ListBox list;
    Button startBtn, openBtn, stopBtn, folderBtn, dlBtn, tokenBtn, modelsBtn;
    Label status;
    TextBox log;
    Process server;
    Process download;
    System.Windows.Forms.Timer poll;
    int pollCount;
    string bundle;
    Model pending;

    static void KillServers()
    {
        foreach (Process p in Process.GetProcessesByName("llama-server"))
        {
            try { p.Kill(); p.WaitForExit(3000); } catch { }
        }
    }

    static bool Healthy(int port)
    {
        try
        {
            HttpWebRequest r = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + port + "/health");
            r.Timeout = 1200;
            r.Proxy = null;
            using (HttpWebResponse resp = (HttpWebResponse)r.GetResponse())
            {
                return (int)resp.StatusCode >= 200 && (int)resp.StatusCode < 300;
            }
        }
        catch { return false; }
    }

    static void Drain(StreamReader reader)
    {
        Thread t = new Thread(delegate ()
        {
            try { while (reader.ReadLine() != null) { } } catch { }
        });
        t.IsBackground = true;
        t.Start();
    }

    static string ResolveBundle()
    {
        string dir = Path.GetDirectoryName(Application.ExecutablePath);
        string sub = Path.Combine(dir, "llama.cpp");
        if (File.Exists(Path.Combine(sub, "llama-server.exe"))) return sub;
        if (File.Exists(Path.Combine(dir, "llama-server.exe"))) return dir;
        string known = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "llama.cpp");
        if (File.Exists(Path.Combine(known, "llama-server.exe"))) return known;
        return dir;
    }

    // pwsh if it is there, otherwise the PowerShell that ships with Windows
    static string FindPowerShell()
    {
        string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string[] cands = {
            @"C:\Program Files\PowerShell\7\pwsh.exe",
            Path.Combine(pf, @"PowerShell\7\pwsh.exe"),
            Path.Combine(pf, @"PowerShell\7-preview\pwsh.exe")
        };
        foreach (string c in cands) if (File.Exists(c)) return c;
        return "powershell.exe";
    }

    static string Human(long b)
    {
        if (b >= 1073741824L) return ((double)b / 1073741824.0).ToString("0.00") + " GB";
        if (b >= 1048576L) return ((double)b / 1048576.0).ToString("0") + " MB";
        return b + " bytes";
    }

    static void Add(List<Model> into, string key, string title, string sub, int port, string args,
                    string file, string repo, string repoFile, long size)
    {
        Model m = new Model();
        m.Key = key; m.Title = title; m.Sub = sub; m.Port = port; m.Args = args;
        m.File = file; m.Repo = repo; m.RepoFile = repoFile; m.SizeBytes = size;
        into.Add(m);
    }

    Button MakeButton(string text, int x, int y, int w)
    {
        Button b = new Button();
        b.Text = text;
        b.SetBounds(x, y, w, 30);
        b.FlatStyle = FlatStyle.System;
        Controls.Add(b);
        return b;
    }

    public App()
    {
        bundle = ResolveBundle();

        Text = "llama.cpp - local models";
        ClientSize = new Size(500, 548);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9f);
        BackColor = Color.White;

        Label title = new Label();
        title.Text = "Local models - one at a time, 8 GB of VRAM";
        title.SetBounds(14, 10, 470, 20);
        title.Font = new Font("Segoe UI", 10f, FontStyle.Bold);
        Controls.Add(title);

        Label hint = new Label();
        hint.Text = "Double-click a model to load it. Missing ones can be downloaded here.";
        hint.SetBounds(14, 32, 470, 18);
        hint.ForeColor = Color.Gray;
        Controls.Add(hint);

        list = new ListBox();
        list.SetBounds(14, 54, 472, 252);
        list.IntegralHeight = false;
        list.DrawMode = DrawMode.OwnerDrawFixed;
        list.ItemHeight = 48;
        list.DoubleClick += delegate { StartSelected(); };
        list.SelectedIndexChanged += delegate { UpdateButtons(); };
        list.DrawItem += delegate (object s, DrawItemEventArgs e)
        {
            if (e.Index < 0) return;
            e.DrawBackground();
            Model m = models[e.Index];
            bool sel = (e.State & DrawItemState.Selected) == DrawItemState.Selected;
            bool have = Present(m);
            Color fg = sel ? SystemColors.HighlightText : (have ? Color.Black : Color.Silver);
            Color fg2 = sel ? SystemColors.HighlightText : (have ? Color.Gray : Color.DarkOrange);
            using (SolidBrush b1 = new SolidBrush(fg)) e.Graphics.DrawString(m.Title, new Font("Segoe UI", 9.75f, FontStyle.Bold), b1, e.Bounds.Left + 6, e.Bounds.Top + 2);
            // the actual file, in full: it is what the command line uses and what people look for on
            // disk, and truncating it to save a line was the single worst thing about this list.
            Color fg3 = sel ? SystemColors.HighlightText : Color.DimGray;
            using (SolidBrush b3 = new SolidBrush(fg3)) e.Graphics.DrawString(m.File, new Font("Consolas", 7.75f), b3, e.Bounds.Left + 6, e.Bounds.Top + 18);
            string sub = have ? m.Sub : "not downloaded - press Download (" + Human(m.SizeBytes) + ")";
            using (SolidBrush b2 = new SolidBrush(fg2)) e.Graphics.DrawString(sub, new Font("Segoe UI", 8.25f), b2, e.Bounds.Left + 6, e.Bounds.Top + 31);
        };
        Controls.Add(list);

        startBtn = MakeButton("Start model", 14, 314, 110);
        startBtn.Click += delegate { StartSelected(); };
        openBtn = MakeButton("Open web UI", 130, 314, 110);
        openBtn.Click += delegate { OpenUi(); };
        stopBtn = MakeButton("Stop", 246, 314, 90);
        stopBtn.Click += delegate { StopServer(); };
        folderBtn = MakeButton("Folder", 342, 314, 80);
        folderBtn.Click += delegate { try { Process.Start("explorer.exe", bundle); } catch { } };

        dlBtn = MakeButton("Download", 14, 350, 140);
        dlBtn.Click += delegate { DownloadSelected(); };
        tokenBtn = MakeButton("HF token...", 160, 350, 110);
        tokenBtn.Click += delegate { AskToken(); };
        modelsBtn = MakeButton("Models folder", 276, 350, 110);
        modelsBtn.Click += delegate { try { Process.Start("explorer.exe", ModelsDir()); } catch { } };

        status = new Label();
        status.SetBounds(14, 386, 472, 22);
        status.Text = "Ready.";
        status.ForeColor = Color.DimGray;
        Controls.Add(status);

        log = new TextBox();
        log.SetBounds(14, 410, 472, 92);
        log.Multiline = true;
        log.ReadOnly = true;
        log.ScrollBars = ScrollBars.Vertical;
        log.BackColor = Color.FromArgb(250, 250, 250);
        log.Font = new Font("Consolas", 8.25f);
        log.WordWrap = false;
        Controls.Add(log);

        Label foot = new Label();
        foot.SetBounds(14, 508, 472, 30);
        foot.ForeColor = Color.Silver;
        foot.Text = "Downloads use Hugging Face xet when available. Nothing leaves this machine otherwise. Closing this window leaves the model running.";
        Controls.Add(foot);

        // the model list and its measured flags
        models = AllModels();

        foreach (Model m in models) list.Items.Add(m.Title);
        list.SelectedIndex = 0;

        poll = new System.Windows.Forms.Timer();
        poll.Interval = 500;
        poll.Tick += delegate { PollHealth(); };

        openBtn.Enabled = false;
        stopBtn.Enabled = false;
        UpdateButtons();
    }

    string ModelsDir() { return Path.Combine(bundle, "models"); }

    bool Present(Model m) { return PresentIn(bundle, m); }

    // "Is this model usable?" Uploaders re-quantise and re-upload under the same filename, so the
    // byte size in the catalogue is a guide, not a promise - three of the six files here came from
    // a different uploader than the one the catalogue now points at. Requiring an exact size would
    // tell the user a perfectly good 20 GB model is missing and offer to download it again. What
    // matters is that a file of roughly the expected size is there at all.
    static bool PresentIn(string dir, Model m)
    {
        try
        {
            string p = Path.Combine(dir, "models", m.File);
            if (!File.Exists(p)) return false;
            if (m.SizeBytes <= 0) return true;
            long len = new FileInfo(p).Length;
            return len >= m.SizeBytes * 6 / 10;
        }
        catch { return false; }
    }

    void UpdateButtons()
    {
        bool downloading = download != null && !download.HasExited;
        Model m = list.SelectedIndex >= 0 && list.SelectedIndex < models.Count ? models[list.SelectedIndex] : null;
        bool have = m != null && Present(m);
        dlBtn.Enabled = !downloading && m != null && !string.IsNullOrEmpty(m.Repo) && !have;
        startBtn.Enabled = !downloading && have;
        if (m != null && !have && !downloading)
        {
            dlBtn.Text = "Download";
        }
        else if (m != null && !have && downloading)
        {
            dlBtn.Text = "Downloading...";
        }
        else
        {
            dlBtn.Text = "Download";
        }
    }

    void Log(string line)
    {
        if (line == null) return;
        if (InvokeRequired)
        {
            try { BeginInvoke((MethodInvoker)delegate () { Log(line); }); } catch { }
            return;
        }
        log.AppendText(line + "\r\n");
        log.SelectionStart = log.TextLength;
        log.ScrollToCaret();
    }

    static string FetchScript()
    {
        string b = ResolveBundle();
        string here = Path.GetDirectoryName(Application.ExecutablePath);
        string cwd = Directory.GetCurrentDirectory();
        string[] cands = {
            Path.Combine(b, "fetch", "llm-fetch.ps1"),      // a built Desktop bundle
            Path.Combine(b, "llm-fetch.ps1"),
            Path.Combine(here, "..", "bin", "llm-fetch.ps1"),   // a plain clone: <repo>\bin\llm-fetch.ps1
            Path.Combine(cwd, "bin", "llm-fetch.ps1"),
            Path.Combine(cwd, "llm-fetch.ps1")
        };
        foreach (string c in cands) if (File.Exists(c)) return Path.GetFullPath(c);
        return null;
    }

    // ------------------------------------------------------------------ download
    void DownloadSelected()
    {
        if (list.SelectedIndex < 0) { status.Text = "Pick a model first."; return; }
        Model m = models[list.SelectedIndex];
        if (string.IsNullOrEmpty(m.Repo)) { status.Text = "This model has no download source in models.manifest.json."; return; }

        string script = FetchScript();
        if (script == null)
        {
            status.Text = "fetch\\llm-fetch.ps1 is missing from the bundle. Rebuild it with llm-desktop.ps1.";
            return;
        }

        string ps = FindPowerShell();
        ProcessStartInfo psi = new ProcessStartInfo(ps,
            "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" -Key " + m.Key);
        psi.WorkingDirectory = bundle;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;

        log.Clear();
        Log("download " + m.Key + " from " + m.Repo);
        Log("  file: " + m.RepoFile + "  (" + Human(m.SizeBytes) + ")");

        try { download = Process.Start(psi); }
        catch (Exception ex)
        {
            status.Text = "Could not start the downloader: " + ex.Message;
            return;
        }

        download.OutputDataReceived += new DataReceivedEventHandler(delegate (object s, DataReceivedEventArgs e) { Log(e.Data); });
        download.ErrorDataReceived += new DataReceivedEventHandler(delegate (object s, DataReceivedEventArgs e) { Log(e.Data); });
        download.EnableRaisingEvents = true;
        download.Exited += delegate (object s, EventArgs e) { DownloadFinished(m); };
        download.BeginOutputReadLine();
        download.BeginErrorReadLine();

        status.Text = "Downloading " + m.Title + " - the window stays responsive.";
        UpdateButtons();
    }

    void DownloadFinished(Model m)
    {
        if (InvokeRequired)
        {
            try { BeginInvoke((MethodInvoker)delegate () { DownloadFinished(m); }); } catch { }
            return;
        }
        int code = 0;
        try { code = download.ExitCode; } catch { }
        download = null;
        if (Present(m))
        {
            status.Text = "Downloaded " + m.Title + " - press Start model.";
            Log("done.");
        }
        else
        {
            status.Text = "Download ended (exit " + code + ") without the model. See the log above.";
        }
        list.Invalidate();
        UpdateButtons();
    }

    // ------------------------------------------------------------------ token
    void AskToken()
    {
        Form dlg = new Form();
        dlg.Text = "Hugging Face token";
        dlg.ClientSize = new Size(440, 156);
        dlg.FormBorderStyle = FormBorderStyle.FixedDialog;
        dlg.MaximizeBox = false;
        dlg.MinimizeBox = false;
        dlg.StartPosition = FormStartPosition.CenterParent;
        dlg.Font = new Font("Segoe UI", 9f);

        Label l = new Label();
        l.SetBounds(12, 10, 416, 32);
        l.Text = "Paste a token from huggingface.co/settings/tokens. It is stored where the hf CLI looks for it.";
        dlg.Controls.Add(l);

        TextBox tb = new TextBox();
        tb.SetBounds(12, 48, 416, 24);
        tb.UseSystemPasswordChar = true;
        dlg.Controls.Add(tb);

        Label l2 = new Label();
        l2.SetBounds(12, 76, 416, 30);
        l2.ForeColor = Color.Gray;
        l2.Text = "Needed for gated repos and for higher rate limits. Public downloads work without it.";
        dlg.Controls.Add(l2);

        Button ok = new Button();
        ok.Text = "Save";
        ok.SetBounds(248, 112, 84, 30);
        ok.DialogResult = DialogResult.OK;
        dlg.Controls.Add(ok);

        Button cancel = new Button();
        cancel.Text = "Cancel";
        cancel.SetBounds(344, 112, 84, 30);
        cancel.DialogResult = DialogResult.Cancel;
        dlg.Controls.Add(cancel);

        dlg.AcceptButton = ok;
        dlg.CancelButton = cancel;

        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        string tok = tb.Text.Trim();
        if (tok.Length == 0) { status.Text = "No token entered."; return; }

        try
        {
            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                                      @".cache\huggingface");
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, "token"), tok, new UTF8Encoding(false));
            Environment.SetEnvironmentVariable("HF_TOKEN", tok);
            status.Text = "Token saved. Downloads will use it.";
            Log("token saved to " + Path.Combine(dir, "token"));
        }
        catch (Exception ex)
        {
            status.Text = "Could not save the token: " + ex.Message;
        }
    }

    // Look for an already-serving model on a background thread, so the window appears instantly
    // instead of after six connection probes.
    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Thread t = new Thread(delegate ()
        {
            Model found = null;
            foreach (Model m in models) { if (Healthy(m.Port)) { found = m; break; } }
            if (found == null) return;
            try
            {
                Invoke((MethodInvoker)delegate ()
                {
                    pending = found;
                    list.SelectedIndex = models.IndexOf(found);
                    openBtn.Enabled = true;
                    stopBtn.Enabled = true;
                    status.Text = "Already running: " + found.Title + " on http://127.0.0.1:" + found.Port + "/";
                });
            }
            catch { }
        });
        t.IsBackground = true;
        t.Start();
    }

    static List<Model> AllModels()
    {
        List<Model> list = new List<Model>();
__MODELS__
        return list;
    }

    void StartSelected()
    {
        if (list.SelectedIndex < 0) { status.Text = "Pick a model first."; return; }
        Model m = models[list.SelectedIndex];
        if (!Present(m))
        {
            status.Text = "That model is not on disk yet - press Download.";
            return;
        }

        status.Text = "Stopping the previous model...";
        Application.DoEvents();
        KillServers();
        Thread.Sleep(600);

        ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(bundle, "llama-server.exe"), m.Args);
        psi.WorkingDirectory = bundle;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;

        try { server = Process.Start(psi); }
        catch (Exception ex)
        {
            status.Text = "Could not start the engine: " + ex.Message;
            return;
        }
        Drain(server.StandardOutput);
        Drain(server.StandardError);

        pending = m;
        pollCount = 0;
        startBtn.Enabled = false;
        stopBtn.Enabled = true;
        openBtn.Enabled = false;
        dlBtn.Enabled = false;
        status.Text = "Loading " + m.Title + "... 5-30 seconds.";
        poll.Start();
    }

    void PollHealth()
    {
        if (pending == null) { poll.Stop(); return; }
        pollCount++;

        if (Healthy(pending.Port))
        {
            poll.Stop();
            startBtn.Enabled = true;
            openBtn.Enabled = true;
            stopBtn.Enabled = true;
            status.Text = "Running: " + pending.Title + "  ->  http://127.0.0.1:" + pending.Port + "/";
            OpenUi();
            return;
        }

        if (server != null && server.HasExited)
        {
            poll.Stop();
            startBtn.Enabled = true;
            openBtn.Enabled = false;
            status.Text = "The engine exited. Is the model file in models\\? Try another model.";
            return;
        }

        if (pollCount > 240)
        {
            poll.Stop();
            startBtn.Enabled = true;
            openBtn.Enabled = false;
            status.Text = "Timed out after 2 minutes. Try another model, or open the Folder and check the log.";
        }
    }

    void OpenUi()
    {
        if (pending == null) { status.Text = "Start a model first."; return; }
        try { Process.Start("http://127.0.0.1:" + pending.Port + "/"); }
        catch (Exception ex) { status.Text = "Could not open the browser: " + ex.Message; }
    }

    void StopServer()
    {
        poll.Stop();
        KillServers();
        pending = null;
        openBtn.Enabled = false;
        stopBtn.Enabled = false;
        startBtn.Enabled = true;
        status.Text = "Stopped. VRAM freed.";
        UpdateButtons();
    }

    static Model Find(List<Model> all, string key)
    {
        foreach (Model m in all) if (string.Equals(m.Key, key, StringComparison.OrdinalIgnoreCase)) return m;
        return null;
    }

    // Scriptable front door, so the launcher can be driven and tested without clicking:
    //   llama-direct.exe --start qwen36     load a model, return immediately
    //   llama-direct.exe --stop             free the GPU
    //   llama-direct.exe --download gemma4  fetch that model from Hugging Face (blocks)
    //   llama-direct.exe --list             what is on disk, what is missing
    static int Headless(string[] argv)
    {
        Model m = Find(AllModels(), argv[1]);
        if (m == null) return 2;
        KillServers();
        Thread.Sleep(600);
        string bundleDir = ResolveBundle();
        ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(bundleDir, "llama-server.exe"), m.Args);
        psi.WorkingDirectory = bundleDir;
        psi.UseShellExecute = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        try { Process.Start(psi); }
        catch { return 1; }
        return 0;
    }

    static int HeadlessDownload(string key)
    {
        Model m = Find(AllModels(), key);
        if (m == null) { Console.Error.WriteLine("unknown model: " + key); return 2; }
        string script = FetchScript();
        if (script == null) { Console.Error.WriteLine("llm-fetch.ps1 not found in the bundle"); return 3; }
        ProcessStartInfo psi = new ProcessStartInfo(FindPowerShell(),
            "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" -Key " + m.Key);
        psi.WorkingDirectory = ResolveBundle();
        psi.UseShellExecute = false;
        try
        {
            using (Process p = Process.Start(psi)) { p.WaitForExit(); return p.ExitCode; }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    static int HeadlessList()
    {
        string bundleDir = ResolveBundle();
        foreach (Model m in AllModels())
        {
            string p = Path.Combine(bundleDir, "models", m.File);
            bool have = PresentIn(bundleDir, m);
            long len = 0;
            try { if (File.Exists(p)) len = new FileInfo(p).Length; } catch { }
            string state;
            if (!have) state = "missing  (" + m.Repo + " :: " + m.RepoFile + ")";
            else if (m.SizeBytes > 0 && Math.Abs(len - m.SizeBytes) > 1048576L) state = "on disk, " + Human(len) + " (catalogue says " + Human(m.SizeBytes) + ")";
            else state = "on disk";
            Console.WriteLine("{0,-8} {1,-34} {2,10}  {3}", m.Key, m.File,
                m.SizeBytes > 0 ? Human(m.SizeBytes) : "-", state);
        }
        return 0;
    }

    [STAThread]
    static int Main(string[] argv)
    {
        // A /target:winexe has no console of its own. When there is a command line, borrow the
        // caller's console so --list and --download print where the user is looking; when the exe
        // is double-clicked there is no console to borrow and nothing is written.
        if (argv.Length >= 1) AttachConsole(-1);

        if (argv.Length >= 2 && argv[0] == "--start") return Headless(argv);
        if (argv.Length >= 2 && argv[0] == "--download") return HeadlessDownload(argv[1]);
        if (argv.Length >= 1 && argv[0] == "--list") return HeadlessList();
        if (argv.Length >= 1 && argv[0] == "--stop") { KillServers(); return 0; }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new App());
        return 0;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AttachConsole(int dwProcessId);
}
'@

$source = $source.Replace('__MODELS__', $modelBlock)

$tmp = Join-Path $env:TEMP 'llama-direct'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$csPath = Join-Path $tmp 'LlamaDirect.cs'
# csc assumes the ANSI code page for a bare .cs file; write UTF-8 with BOM so the compiler sees ASCII
# only anyway, but this keeps any future non-ASCII label intact.
[System.IO.File]::WriteAllText($csPath, $source, (New-Object System.Text.UTF8Encoding($true)))

$csc = @(
    "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw "no C# compiler found (.NET Framework 4.x csc.exe)" }

New-Item -ItemType Directory -Force -Path $Bundle | Out-Null
$exePath = Join-Path $Bundle 'llama-direct.exe'
# Compile beside the target, never on top of it: if the app is open, Windows locks the image and csc
# fails with "cannot write output file", which used to be swallowed - the next line reported "built"
# with the *old* file still in place, which is how a fix can look applied and not be.
$stage = Join-Path $tmp 'llama-direct.exe'
if (Test-Path $stage) { Remove-Item $stage -Force }
& $csc /nologo /target:winexe /optimize+ "/out:$stage" `
    /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll $csPath 2>&1 |
    ForEach-Object { if ($_ -match 'error') { Write-Host "  $_" -ForegroundColor Red } }
if (-not (Test-Path $stage)) { throw "compile failed (see the errors above)" }
$stamp = (Get-Item $stage).LastWriteTime
try {
    Copy-Item $stage $exePath -Force -ErrorAction Stop
    Copy-Item $stage $DesktopCopy -Force -ErrorAction Stop
} catch {
    $spare = "$exePath.new.exe"
    Copy-Item $stage $spare -Force
    Write-Host ""
    Write-Host "  the launcher is open, so the file is locked - the new build is here:" -ForegroundColor Yellow
    Write-Host "    $spare" -ForegroundColor Yellow
    Write-Host "  close the launcher window, then run this script again (or rename .new.exe over it)." -ForegroundColor Yellow
    exit 2
}
if ((Get-Item $exePath).LastWriteTime -ne $stamp) { throw "the exe on disk is still the old one" }

Write-Host ""
Write-Host ("  built {0}  ({1:N0} KB)" -f $exePath, ((Get-Item $exePath).Length / 1KB)) -ForegroundColor Green
Write-Host ("  copied to {0}" -f $DesktopCopy) -ForegroundColor Green
Write-Host "  double-click it, pick a model, the chat page opens by itself." -ForegroundColor DarkGray
Write-Host ""
