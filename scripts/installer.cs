using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Security;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace PotatoAutoBuild
{
    internal sealed class InstallerForm : Form
    {
        private readonly TextBox gameDirectory = new TextBox { Name = "GameDirectory", AccessibleName = "游戏目录" };
        private readonly Button browse = new Button { Text = "浏览…", AutoSize = true, MinimumSize = new Size(84, 32) };
        private readonly Button install = new Button { Name = "Install", Text = "安装 / 更新", AutoSize = true, MinimumSize = new Size(112, 34) };
        private readonly Button uninstall = new Button { Name = "Uninstall", Text = "卸载", AutoSize = true, MinimumSize = new Size(96, 34) };
        private readonly Label status = new Label { Name = "Status", Dock = DockStyle.Fill, Padding = new Padding(0, 12, 0, 0) };
        private bool working;

        internal InstallerForm()
        {
            var version = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>();
            Text = "土豆兄弟助手安装程序 " + version.InformationalVersion;
            AutoScaleMode = AutoScaleMode.Font;
            Font = new Font("Microsoft YaHei UI", 10);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            ClientSize = new Size(620, 230);

            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(22), ColumnCount = 2, RowCount = 4 };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            gameDirectory.Anchor = AnchorStyles.Left | AnchorStyles.Right;
            var actions = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Fill };
            actions.Controls.Add(install);
            actions.Controls.Add(uninstall);
            layout.Controls.Add(new Label { Text = "游戏目录", AutoSize = true }, 0, 0);
            layout.Controls.Add(gameDirectory, 0, 1);
            layout.Controls.Add(browse, 1, 1);
            layout.Controls.Add(status, 0, 2);
            layout.SetColumnSpan(status, 2);
            layout.Controls.Add(actions, 0, 3);
            layout.SetColumnSpan(actions, 2);
            Controls.Add(layout);

            browse.Click += (sender, args) => BrowseGameDirectory();
            install.Click += async (sender, args) => await RunAsync(true);
            uninstall.Click += async (sender, args) => await RunAsync(false);
            gameDirectory.TextChanged += (sender, args) => ShowDirectoryStatus();
            FormClosing += (sender, args) => { if (working && args.CloseReason == CloseReason.UserClosing) args.Cancel = true; };
            gameDirectory.Text = Installer.FindGameDirectory();
            ShowDirectoryStatus();
        }

        private string GamePath
        {
            get { return gameDirectory.Text.Trim().Trim('"'); }
        }

        private void ShowDirectoryStatus()
        {
            bool valid = Installer.IsGameDirectory(GamePath);
            install.Enabled = uninstall.Enabled = valid;
            status.Text = valid ? "请先退出游戏，再安装或卸载。" : "请选择包含 Brotato.exe 的游戏目录。";
        }

        private void BrowseGameDirectory()
        {
            using (var dialog = new FolderBrowserDialog())
            {
                dialog.Description = "请选择包含 Brotato.exe 的游戏目录。";
                dialog.ShowNewFolderButton = false;
                dialog.SelectedPath = GamePath;
                if (dialog.ShowDialog(this) == DialogResult.OK)
                    gameDirectory.Text = dialog.SelectedPath;
            }
        }

        private async Task RunAsync(bool installing)
        {
            string path = GamePath;
            working = true;
            gameDirectory.Enabled = browse.Enabled = install.Enabled = uninstall.Enabled = false;
            status.Text = installing ? "正在安装…" : "正在卸载…";
            try
            {
                await Task.Run(() => Installer.Run(path, installing));
                status.Text = installing ? "安装完成。请从 Steam 启动游戏，按 Alt+2 查看助手。" : "卸载完成。已移除助手模组和自动加载入口。";
            }
            catch (Exception error)
            {
                status.Text = (installing ? "安装失败。" : "卸载失败。") + Environment.NewLine + error.Message;
            }
            finally
            {
                working = false;
                gameDirectory.Enabled = browse.Enabled = true;
                install.Enabled = uninstall.Enabled = Installer.IsGameDirectory(path);
            }
        }

        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (var form = new InstallerForm())
                Application.Run(form);
        }
    }

    internal static class Installer
    {
        internal static bool IsGameDirectory(string path)
        {
            return !string.IsNullOrWhiteSpace(path) && File.Exists(path.TrimEnd('\\', '/') + @"\Brotato.exe");
        }

        internal static string FindGameDirectory()
        {
            const string machineSoftware = @"HKEY_LOCAL_MACHINE\SOFTWARE\";
            string path = ReadRegistryPath(machineSoftware + @"Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1942280", "InstallLocation");
            if (IsGameDirectory(path))
                return path;

            string[] steamPaths = {
                ReadRegistryPath(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath"),
                ReadRegistryPath(machineSoftware + @"WOW6432Node\Valve\Steam", "InstallPath"),
                ReadRegistryPath(machineSoftware + @"Valve\Steam", "InstallPath")
            };
            foreach (string steamPath in steamPaths)
            {
                if (string.IsNullOrEmpty(steamPath))
                    continue;
                path = steamPath.TrimEnd('\\', '/') + @"\steamapps\common\Brotato";
                if (IsGameDirectory(path))
                    return path;
            }
            return string.Empty;
        }

        private static string ReadRegistryPath(string key, string name)
        {
            try { return Registry.GetValue(key, name, null) as string; }
            catch (SecurityException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        }

        internal static void Run(string gamePath, bool installing)
        {
            using (var operation = new Mutex(false, @"Local\PotatoAutoBuildSetup"))
            {
                bool acquired;
                try { acquired = operation.WaitOne(0); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired)
                    throw new InvalidOperationException("另一个安装程序正在操作，请稍后重试。");
                try { RunScript(gamePath, installing); }
                finally { operation.ReleaseMutex(); }
            }
        }

        private static void RunScript(string gamePath, bool installing)
        {
            string tempPath = Path.GetFullPath(Path.GetTempPath());
            string stagingPath = Path.Combine(tempPath, "Potato-AutoBuild-" + Guid.NewGuid().ToString("N"));
            DirectoryInfo staging = Directory.CreateDirectory(stagingPath);
            try
            {
                Assembly bundle = Assembly.GetExecutingAssembly();
                foreach (string name in bundle.GetManifestResourceNames())
                {
                    string path = Path.Combine(staging.FullName, name.Replace('/', '\\'));
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    using (Stream source = bundle.GetManifestResourceStream(name))
                    using (Stream target = File.Create(path))
                        source.CopyTo(target);
                }

                // 路径通过环境变量传给脚本，避免路径中的字符被当作命令解析。
                const string command = "[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); " +
                    "try { & $env:POTATO_SETUP_SCRIPT -GamePath $env:POTATO_SETUP_GAME | Out-Null } " +
                    "catch [UnauthorizedAccessException] { [Console]::Error.WriteLine('没有权限写入游戏目录。请以管理员身份运行安装程序。'); exit 1 } " +
                    "catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }";
                string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
                var start = new ProcessStartInfo(powershell, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"" + command + "\"")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };
                start.EnvironmentVariables["POTATO_SETUP_SCRIPT"] = Path.Combine(staging.FullName, installing ? @"scripts\install.ps1" : @"scripts\uninstall.ps1");
                start.EnvironmentVariables["POTATO_SETUP_GAME"] = gamePath;
                using (Process process = Process.Start(start))
                {
                    Task<string> output = process.StandardOutput.ReadToEndAsync();
                    string error = process.StandardError.ReadToEnd().Trim();
                    process.WaitForExit();
                    string result = output.GetAwaiter().GetResult().Trim();
                    if (process.ExitCode != 0)
                    {
                        string detail = error.Length > 0 ? error : result;
                        throw new InvalidOperationException(detail.Length > 0 ? detail : "安装脚本退出代码为 " + process.ExitCode + "。");
                    }
                }
            }
            finally
            {
                try { staging.Delete(true); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
    }
}
