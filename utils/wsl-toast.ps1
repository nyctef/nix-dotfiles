param(
    [string]$Title = "WSL",
    [string]$Message = "Notification"
)

[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null

$Template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$RawXml = [xml] $Template.GetXml()

($RawXml.toast.visual.binding.text | Where-Object { $_.id -eq "1" }).AppendChild($RawXml.CreateTextNode($Title)) > $null
($RawXml.toast.visual.binding.text | Where-Object { $_.id -eq "2" }).AppendChild($RawXml.CreateTextNode($Message)) > $null

$SerializedXml = New-Object Windows.Data.Xml.Dom.XmlDocument
$SerializedXml.LoadXml($RawXml.OuterXml)

$Toast = [Windows.UI.Notifications.ToastNotification]::new($SerializedXml)
$Toast.Tag = "WSL"
$Toast.Group = "WSL"
$Toast.ExpirationTime = [DateTimeOffset]::Now.AddMinutes(5)

$Notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("WSL")
$Notifier.Show($Toast)
