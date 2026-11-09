using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Microsoft.Win32;

namespace LanDrop;

public sealed class PeerVm
{
    public Peer Peer { get; init; }
    public string Name => Peer.Name;
    public string Subtitle => $"{Peer.PlatformLabel} · {Peer.Endpoint}";
    public string Emoji => Peer.Platform switch
    {
        "macos" => "💻",
        "android" => "📱",
        "harmony" or "harmonyos" or "ohos" => "📲",
        "windows" => "🖥",
        _ => "📡"
    };
}

public sealed class InboxVm
{
    public InboxItem Item { get; init; }
    public string Title => Item.Name;
    public string Subtitle => Item.SizeText;
    public string Time => Item.MTime.ToString("HH:mm");
    public string Emoji => Item.Kind == "text" ? "📝" : "📄";
}

public sealed class TransferVm : System.ComponentModel.INotifyPropertyChanged
{
    public event System.ComponentModel.PropertyChangedEventHandler PropertyChanged;
    public Transfer Transfer { get; init; }
    public void Refresh()
    {
        PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(nameof(Percent)));
        PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(nameof(Status)));
    }
    public string Title => Transfer.FileName;
    public string Direction => Transfer.Send ? "发送" : "接收";
    public string Subtitle => Transfer.PeerName;
    public string Status => Transfer.State switch
    {
        "preparing" => "准备中…",
        "running" => $"{Transfer.Progress * 100:0}% · {Transfer.SpeedText}",
        "done" => $"完成 · {InboxItem.FormatSize(Transfer.Total)}",
        "failed" => Transfer.Error ?? "失败",
        "cancelled" => "已取消",
        _ => Transfer.State
    };
    public double Percent => Transfer.Progress * 100;
    public string State => Transfer.State;
    public string LocalPath => Transfer.LocalPath;
}

public sealed partial class MainWindow : Window
{
    private readonly AppConfig _cfg;
    private readonly InboxStore _inbox;
    private readonly HttpServer _server;
    private readonly Discovery _discovery;
    private readonly Dictionary<string, Peer> _peers = new();
    private readonly List<Transfer> _transfers = new();
    private readonly Dictionary<string, Transfer> _inbound = new();
    private readonly object _gate = new();
    private readonly ObservableCollection<PeerVm> _peerItems = new();
    private readonly ObservableCollection<InboxVm> _inboxItems = new();
    private readonly ObservableCollection<TransferVm> _transferItems = new();
    private readonly DispatcherQueue _queue;
    private DateTime _lastTransferRefresh = DateTime.MinValue;
    private string _inboxSignature = "";
    private string _peerSignature = "";

    private static void Boot(string msg)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanDrop");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "boot.log"), $"{DateTime.Now:HH:mm:ss.fff} {msg}\n");
        }
        catch { }
    }

    public MainWindow()
    {
        Boot("ctor start");
        _cfg = AppConfig.Load();
        Boot("config ok");
        _inbox = new InboxStore(_cfg.Inbox);
        _server = new HttpServer(_cfg, _inbox);
        _discovery = new Discovery(_cfg, () => _server.Port == 0 ? _cfg.Port : _server.Port);
        _queue = DispatcherQueue.GetForCurrentThread();

        try
        {
            InitializeComponent();
            Boot("xaml ok");
        }
        catch (Exception ex)
        {
            Boot("xaml failed: " + ex);
            throw;
        }
        DeviceNameText.Text = _cfg.Name;
        DeviceList.ItemsSource = _peerItems;
        InboxList.ItemsSource = _inboxItems;
        TransferList.ItemsSource = _transferItems;

        TrySetUpWindow();

        _server.Received += OnReceived;
        _server.Progress += OnProgress;
        _discovery.PeerSeen += OnPeerSeen;

        ApplyAutostart(_cfg.LaunchAtLogin);
        Boot("ui ok");
        StartReceiver();
        Boot("server started");
        RefreshInbox();

        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        timer.Tick += (_, _) =>
        {
            PrunePeers();
            RefreshInbox();
        };
        timer.Start();
    }

    private void TrySetUpWindow()
    {
        try
        {
            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
            var id = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hwnd);
            var appWindow = AppWindow.GetFromWindowId(id);
            if (appWindow.Presenter is OverlappedPresenter presenter) presenter.Maximize();
        }
        catch { }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    // MARK: 收发

    private void StartReceiver()
    {
        if (!_server.Start())
        {
            FooterText.Text = "端口 47823-47832 都被占用了，接收服务启动失败";
            UpdateStatus();
            return;
        }
        _discovery.Start();
        _discovery.Probe();
        UpdateStatus();
    }

    private void OnToggleClick(object sender, RoutedEventArgs e)
    {
        if (_server.Running)
        {
            _server.Stop();
            _discovery.Stop();
        }
        else
        {
            StartReceiver();
        }
        UpdateStatus();
    }

    private void UpdateStatus()
    {
        if (_server.Running)
        {
            StatusText.Text = $"正在接收 · {PrimaryIp()}:{_server.Port}";
            ToggleButton.Content = "停止";
            FooterText.Text = "UDP 47824 发现 · HTTP 传输 · 明文局域网，建议只在家里的 Wi-Fi 使用";
        }
        else
        {
            StatusText.Text = "未启动";
            ToggleButton.Content = "启动";
            FooterText.Text = "接收服务已停止，点「启动」重新开始";
        }
    }

    private void OnPeerSeen(Peer peer)
    {
        lock (_gate)
        {
            if (_peers.TryGetValue(peer.Id, out var existing))
            {
                existing.Name = peer.Name;
                existing.Platform = peer.Platform;
                existing.Host = peer.Host;
                existing.Port = peer.Port;
                existing.PinRequired = peer.PinRequired;
                existing.LastSeen = DateTime.Now;
            }
            else
            {
                _peers[peer.Id] = peer;
            }
        }
        _queue.TryEnqueue(RefreshDevices);
    }

    private void PrunePeers()
    {
        lock (_gate)
        {
            foreach (var id in _peers.Values.Where(p => !p.Online).Select(p => p.Id).ToList())
                _peers.Remove(id);
        }
        RefreshDevices();
    }

    private void RefreshDevices()
    {
        var selected = SelectedPeer()?.Id;
        List<Peer> peers;
        lock (_gate) peers = _peers.Values.OrderBy(p => p.Name).ToList();
        var signature = string.Join("|", peers.Select(p => $"{p.Id}:{p.Name}:{p.Endpoint}:{p.PinRequired}"));
        if (signature == _peerSignature && selected == null) return;
        _peerSignature = signature;
        _peerItems.Clear();
        foreach (var peer in peers)
        {
            _peerItems.Add(new PeerVm { Peer = peer });
            if (peer.Id == selected) DeviceList.SelectedIndex = _peerItems.Count - 1;
        }
    }

    private void RefreshInbox()
    {
        var items = _inbox.List();
        var signature = string.Join("|", items.Select(i => $"{i.Name}:{i.Size}:{i.MTime.Ticks}"));
        if (signature == _inboxSignature) return;
        _inboxSignature = signature;
        _inboxItems.Clear();
        foreach (var item in items) _inboxItems.Add(new InboxVm { Item = item });
    }

    private void OnProgress(string fileId, string name, long received, long total, string ip)
    {
        lock (_gate)
        {
            if (!_inbound.TryGetValue(fileId, out var transfer))
            {
                transfer = new Transfer
                {
                    FileName = name,
                    PeerName = ip,
                    Send = false,
                    Total = total,
                    State = "running"
                };
                _inbound[fileId] = transfer;
                _transfers.Insert(0, transfer);
            }
            transfer.Sent = received;
            if (total > 0) transfer.Total = total;
        }
        if ((DateTime.Now - _lastTransferRefresh).TotalMilliseconds < 200) return;
        _lastTransferRefresh = DateTime.Now;
        _queue.TryEnqueue(RefreshTransfers);
    }

    private void OnReceived(InboxItem item, string fileId)
    {
        lock (_gate)
        {
            if (!string.IsNullOrEmpty(fileId) && _inbound.TryGetValue(fileId, out var transfer))
            {
                transfer.State = "done";
                transfer.Sent = transfer.Total;
                transfer.LocalPath = item.Path;
            }
        }
        _queue.TryEnqueue(() =>
        {
            RefreshInbox();
            RefreshTransfers();
            FooterText.Text = $"收到 {item.Name}";
        });
    }

    private void RefreshTransfers()
    {
        List<Transfer> list;
        lock (_gate) list = _transfers.ToList();
        var sameSet = list.Count == _transferItems.Count &&
                      list.Select(t => t.Id).SequenceEqual(_transferItems.Select(v => v.Transfer.Id));
        if (sameSet)
        {
            foreach (var vm in _transferItems) vm.Refresh();
        }
        else
        {
            _transferItems.Clear();
            foreach (var t in list) _transferItems.Add(new TransferVm { Transfer = t });
        }

    }

    // MARK: 发送

    private async void OnSendClick(object sender, RoutedEventArgs e)
    {
        var peer = SelectedPeer();
        if (peer == null)
        {
            await ShowMessage("先选一台设备", "在左侧点一下要发送到的设备，再点发送文件。");
            return;
        }
        var files = await PickFilesAsync();
        if (files.Count == 0) return;
        SendFiles(peer, files);
    }

    private void SendFiles(Peer peer, IReadOnlyList<StorageFile> files)
    {
        foreach (var file in files)
        {
            var transfer = new Transfer
            {
                FileName = file.Name,
                PeerName = peer.Name,
                Send = true,
                Total = (long)new FileInfo(file.Path).Length,
                LocalPath = file.Path,
                State = "preparing",
                Cts = new CancellationTokenSource()
            };
            lock (_gate) _transfers.Insert(0, transfer);
            RefreshTransfers();
            _ = Task.Run(() => UploadAsync(peer, file.Path, transfer));
        }
    }

    private async Task UploadAsync(Peer peer, string path, Transfer transfer)
    {
        var client = new PeerClient { Pin = PinFor(peer) };
        try
        {
            transfer.State = "running";
            var outcome = await client.UploadAsync(peer, path, transfer.FileId, (sent, total) =>
            {
                transfer.Sent = sent;
                transfer.Total = total;
                if ((DateTime.Now - _lastTransferRefresh).TotalMilliseconds < 200) return;
                _lastTransferRefresh = DateTime.Now;
                _queue.TryEnqueue(RefreshTransfers);
            }, transfer.Cts.Token);

            if (outcome == UploadOutcome.PinRequired)
            {
                var pin = await PromptPinAsync(peer, true);
                if (!string.IsNullOrEmpty(pin))
                {
                    _cfg.PeerPins[peer.Id] = pin;
                    _cfg.Save();
                    client.Pin = pin;
                    outcome = await client.UploadAsync(peer, path, transfer.FileId, (sent, total) =>
                    {
                        transfer.Sent = sent;
                        transfer.Total = total;
                        _queue.TryEnqueue(RefreshTransfers);
                    }, transfer.Cts.Token);
                }
            }

            transfer.State = outcome switch
            {
                UploadOutcome.Done => "done",
                UploadOutcome.Cancelled => "cancelled",
                _ => "failed"
            };
            if (transfer.State == "failed") transfer.Error = "发送失败";
            if (transfer.State == "done") transfer.LocalPath = path;
        }
        catch
        {
            transfer.State = "failed";
            transfer.Error = "发送失败";
        }
        _queue.TryEnqueue(() =>
        {
            RefreshTransfers();
            if (transfer.State == "done") FooterText.Text = $"已发送 {transfer.FileName}";
        });
    }

    private async void OnTextClick(object sender, RoutedEventArgs e)
    {
        var peer = SelectedPeer();
        if (peer == null)
        {
            await ShowMessage("先选一台设备", "在左侧点一下要发送到的设备。");
            return;
        }
        var box = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 160,
            PlaceholderText = "链接、验证码、一段配置…"
        };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = $"发送文本到 {peer.Name}",
            Content = box,
            PrimaryButtonText = "发送",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || string.IsNullOrWhiteSpace(box.Text)) return;
        var client = new PeerClient { Pin = PinFor(peer) };
        var ok = await client.SendTextAsync(peer, box.Text, null, CancellationToken.None);
        FooterText.Text = ok ? "文本已发送" : "文本发送失败";
    }

    // MARK: 收件箱 / 传输操作

    private void OnInboxDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        var vm = (e.OriginalSource as FrameworkElement)?.DataContext as InboxVm;
        if (vm != null) OpenPath(vm.Item.Path);
    }

    private async void OnInboxRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var vm = (e.OriginalSource as FrameworkElement)?.DataContext as InboxVm;
        if (vm == null) return;
        var flyout = new MenuFlyout();
        var open = new MenuFlyoutItem { Text = "打开" };
        open.Click += (_, _) => OpenPath(vm.Item.Path);
        var reveal = new MenuFlyoutItem { Text = "在文件夹中显示" };
        reveal.Click += (_, _) => RevealInExplorer(vm.Item.Path);
        var copy = new MenuFlyoutItem { Text = "复制文件" };
        copy.Click += async (_, _) => await CopyFileToClipboard(vm.Item.Path);
        var delete = new MenuFlyoutItem { Text = "删除" };
        delete.Click += async (_, _) =>
        {
            try { File.Delete(vm.Item.Path); } catch { }
            RefreshInbox();
            await Task.CompletedTask;
        };
        flyout.Items.Add(open);
        flyout.Items.Add(reveal);
        flyout.Items.Add(copy);
        flyout.Items.Add(new MenuFlyoutSeparator());
        flyout.Items.Add(delete);
        flyout.ShowAt((FrameworkElement)sender, e.GetPosition((UIElement)sender));
    }

    private void OnTransferRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var vm = (e.OriginalSource as FrameworkElement)?.DataContext as TransferVm;
        if (vm == null) return;
        var flyout = new MenuFlyout();
        if (vm.State == "done" && !string.IsNullOrEmpty(vm.LocalPath) && File.Exists(vm.LocalPath))
        {
            var copy = new MenuFlyoutItem { Text = "复制文件" };
            copy.Click += async (_, _) => await CopyFileToClipboard(vm.LocalPath);
            var reveal = new MenuFlyoutItem { Text = "在文件夹中显示" };
            reveal.Click += (_, _) => RevealInExplorer(vm.LocalPath);
            flyout.Items.Add(copy);
            flyout.Items.Add(reveal);
            flyout.Items.Add(new MenuFlyoutSeparator());
        }
        if (vm.State is "running" or "preparing")
        {
            var cancel = new MenuFlyoutItem { Text = "取消" };
            cancel.Click += (_, _) =>
            {
                vm.Transfer.Cts?.Cancel();
                vm.Transfer.State = "cancelled";
                RefreshTransfers();
            };
            flyout.Items.Add(cancel);
        }
        if (flyout.Items.Count > 0)
            flyout.ShowAt((FrameworkElement)sender, e.GetPosition((UIElement)sender));
    }

    // MARK: 贴纸

    private async void OnStickerClick(object sender, RoutedEventArgs e)
    {
        var peer = SelectedPeer();
        var host = peer?.Host ?? PrimaryIp();
        var port = peer?.Port ?? (_server.Port == 0 ? _cfg.Port : _server.Port);
        var id = peer?.Id ?? _cfg.Id;
        var name = peer?.Name ?? _cfg.Name;
        var pin = peer?.PinRequired ?? _cfg.PinEnabled;
        var payload = NfcTag.Payload(id, name, host, port, pin);
        var box = new TextBox
        {
            Text = payload,
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            FontFamily = new FontFamily("Consolas"),
            Height = 72
        };
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(new TextBlock
        {
            Text = $"NFC 贴纸 · {name}\n占用约 {NfcTag.Bytes(payload)} 字节（NTAG213 起）。\n" +
                   "Windows 一般没有 NFC 读卡器，这里生成贴纸内容：用手机端 LanDrop 写入，\n" +
                   "或粘到任意 NDEF 写入工具里。写入后手机碰贴纸即可把文件传到这台电脑。",
            TextWrapping = TextWrapping.Wrap
        });
        panel.Children.Add(box);
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "NFC 贴纸",
            Content = panel,
            PrimaryButtonText = "复制",
            CloseButtonText = "关闭",
            DefaultButton = ContentDialogButton.Primary
        };
        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            var package = new DataPackage();
            package.SetText(payload);
            Clipboard.SetContent(package);
            FooterText.Text = "贴纸内容已复制";
        }
    }

    // MARK: 捐赠

    private async void OnDonateClick(object sender, RoutedEventArgs e)
    {
        var panel = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
        panel.Children.Add(new TextBlock
        {
            Text = "LanDrop 免费、无广告、不登录、不上传云端。\n如果它帮到了你，可以自愿捐赠；不捐赠不影响任何功能。",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]
        });
        var imagePath = Path.Combine(AppContext.BaseDirectory, "Assets", "donate-wechat.png");
        if (File.Exists(imagePath))
        {
            panel.Children.Add(new Image
            {
                Source = new BitmapImage(new Uri("file:///" + imagePath.Replace('\\', '/'))),
                Height = 320,
                Stretch = Stretch.Uniform
            });
        }
        panel.Children.Add(new TextBlock
        {
            Text = "收款方：皓子(**皓) · 微信支付",
            FontSize = 10,
            Foreground = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"]
        });
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "自愿捐赠",
            Content = new ScrollViewer { Content = panel, MaxHeight = 520 },
            CloseButtonText = "关闭",
            DefaultButton = ContentDialogButton.Close
        };
        await dialog.ShowAsync();
    }

    // MARK: 设置

    private async void OnSettingsClick(object sender, RoutedEventArgs e)
    {
        var nameBox = new TextBox { Text = _cfg.Name, Header = "设备名" };
        var inboxBox = new TextBox { Text = _cfg.Inbox, Header = "收件箱" };
        var pinToggle = new CheckBox { Content = "启用配对码（对方发送前需输入）", IsChecked = _cfg.PinEnabled };
        var pinBox = new TextBox { Text = _cfg.Pin, MaxLength = 6, Header = "配对码（6 位数字）" };
        var autostart = new CheckBox { Content = "开机自动启动（登录后静默接收）", IsChecked = _cfg.LaunchAtLogin };
        var panel = new StackPanel { Spacing = 10, Width = 420 };
        panel.Children.Add(nameBox);
        panel.Children.Add(inboxBox);
        panel.Children.Add(pinToggle);
        panel.Children.Add(pinBox);
        panel.Children.Add(autostart);
        panel.Children.Add(new TextBlock
        {
            Text = "协议为明文 HTTP，配对码只用于防误触，不加密内容。",
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]
        });

        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "设置",
            Content = panel,
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        _cfg.Name = string.IsNullOrWhiteSpace(nameBox.Text) ? _cfg.Name : nameBox.Text.Trim();
        _cfg.Inbox = inboxBox.Text.Trim();
        _cfg.PinEnabled = pinToggle.IsChecked == true;
        if (pinBox.Text.Trim().Length == 6) _cfg.Pin = pinBox.Text.Trim();
        _cfg.LaunchAtLogin = autostart.IsChecked == true;
        _cfg.Save();
        ApplyAutostart(_cfg.LaunchAtLogin);
        DeviceNameText.Text = _cfg.Name;
        FooterText.Text = "设置已保存（收件箱目录重启后生效）";
    }

    // MARK: 工具

    private Peer SelectedPeer() =>
        DeviceList.SelectedItem is PeerVm vm ? vm.Peer : null;

    private string PinFor(Peer peer)
    {
        if (!peer.PinRequired) return null;
        return _cfg.PeerPins.TryGetValue(peer.Id, out var pin) ? pin : null;
    }

    private async Task<IReadOnlyList<StorageFile>> PickFilesAsync()
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add("*");
        return await picker.PickMultipleFilesAsync();
    }

    private Task<string> PromptPinAsync(Peer peer, bool _)
    {
        var tcs = new TaskCompletionSource<string>();
        _queue.TryEnqueue(async () =>
        {
            var box = new TextBox { MaxLength = 6, PlaceholderText = "6 位数字" };
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = $"「{peer.Name}」需要配对码",
                Content = box,
                PrimaryButtonText = "确定",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Primary
            };
            var result = await dialog.ShowAsync();
            tcs.TrySetResult(result == ContentDialogResult.Primary ? box.Text.Trim() : null);
        });
        return tcs.Task;
    }

    private async Task ShowMessage(string title, string message)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = title,
            Content = message,
            CloseButtonText = "知道了"
        };
        await dialog.ShowAsync();
    }

    private static void OpenPath(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch { }
    }

    public static void RevealInExplorer(string path)
    {
        if (!File.Exists(path)) return;
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        }
        catch { }
    }

    public static async Task CopyFileToClipboard(string path)
    {
        if (!File.Exists(path)) return;
        var file = await StorageFile.GetFileFromPathAsync(path);
        var package = new DataPackage();
        package.RequestedOperation = DataPackageOperation.Copy;
        package.SetStorageItems(new[] { file });
        Clipboard.SetContent(package);
    }

    private static void ApplyAutostart(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
            if (key == null) return;
            if (enabled) key.SetValue("LanDrop", $"\"{Environment.ProcessPath}\"");
            else key.DeleteValue("LanDrop", false);
        }
        catch { }
    }

    private static string PrimaryIp()
    {
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                foreach (var ua in nic.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork &&
                        !IPAddress.IsLoopback(ua.Address))
                        return ua.Address.ToString();
                }
            }
        }
        catch { }
        return "127.0.0.1";
    }

    private void OnRefreshClick(object sender, RoutedEventArgs e) => _discovery.Probe();

    private void OnDeviceDragOver(object sender, DragEventArgs e)
    {
        e.AcceptedOperation = e.DataView.Contains(StandardDataFormats.StorageItems)
            ? DataPackageOperation.Copy
            : DataPackageOperation.None;
    }

    private async void OnDeviceDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        var files = items.OfType<StorageFile>().ToList();
        if (files.Count == 0) return;
        var vm = (e.OriginalSource as FrameworkElement)?.DataContext as PeerVm;
        var peer = vm?.Peer ?? SelectedPeer();
        if (peer == null) return;
        SendFiles(peer, files);
    }

    private void OnTabClick(object sender, RoutedEventArgs e)
    {
        var showInbox = ReferenceEquals(sender, InboxTab);
        InboxTab.IsChecked = showInbox;
        TransfersTab.IsChecked = !showInbox;
        InboxList.Visibility = showInbox ? Visibility.Visible : Visibility.Collapsed;
        TransferList.Visibility = showInbox ? Visibility.Collapsed : Visibility.Visible;
    }
}
