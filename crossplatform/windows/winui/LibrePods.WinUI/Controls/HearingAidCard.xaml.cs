using System;
using LibrePods.WinUI.Ipc;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace LibrePods.WinUI.Controls;

/// Hearing assistance (AirPods Pro 3, experimental accessibility amplification).
/// A toggle plus amplification/balance sliders and a conversation-boost switch. The
/// daemon enables hearing-assist over AAP and writes the settings to the ATT/GATT.
/// Slider changes are debounced (each apply is a ~1.3 s enable + ATT round-trip).
public sealed partial class HearingAidCard : UserControl
{
    public DaemonClient? Client { get; set; }

    private readonly DispatcherTimer _debounce = new() { Interval = TimeSpan.FromMilliseconds(500) };

    public HearingAidCard()
    {
        InitializeComponent();
        _debounce.Tick += (_, _) => { _debounce.Stop(); Apply(); };
    }

    private void Enable_Toggled(object sender, RoutedEventArgs e)
    {
        bool on = EnableSwitch.IsOn;
        AmpSlider.IsEnabled = on;
        BalanceSlider.IsEnabled = on;
        ConvBoostSwitch.IsEnabled = on;
        _debounce.Stop();
        Apply(); // enabling/disabling applies immediately
    }

    private void Settings_Changed(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (EnableSwitch.IsOn) { _debounce.Stop(); _debounce.Start(); }
    }

    private void ConvBoost_Toggled(object sender, RoutedEventArgs e)
    {
        if (EnableSwitch.IsOn) { _debounce.Stop(); _debounce.Start(); }
    }

    private void Apply()
    {
        var amp = (float)(AmpSlider.Value / 100.0);   // 0..1
        var bal = (float)(BalanceSlider.Value / 100.0); // -1..1
        Client?.SetHearingAid(EnableSwitch.IsOn, amp, bal, ConvBoostSwitch.IsOn);
    }
}
