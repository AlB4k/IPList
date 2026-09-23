# IPList для Windows

Windows-версия IPList 1.4.0 предназначена для Windows 10 22H2 и Windows 11 (win-x64). Windows CI собирает self-contained ZIP, которому не требуется установленный .NET. В архив входят приложение и документы `README.md` и `THIRD_PARTY_NOTICES.md`; персональные конфигурации и ключи в него не входят. Данные приложения хранятся в `%LOCALAPPDATA%\IPList`; файлы `.vpn` не поддерживаются, исходные `.conf` не изменяются.

Пока релизный архив не опубликован, проверяйте сборку из исходников. Нужен .NET SDK 10; сборка приложения выполняется на Windows:

```powershell
dotnet build Windows/IPList.Windows.sln -c Release
dotnet test Windows/tests/IPList.Core.Tests/IPList.Core.Tests.csproj -c Release --no-build
dotnet publish Windows/src/IPList.App/IPList.App.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o artifacts/publish
```

Автоматическая Windows CI выполняет эти проверки и прикладывает ZIP вместе с SHA-256 контрольной суммой к запуску workflow. Это CI-артефакт, а не опубликованный релиз; перед распространением нужны ручные проверки на чистых Windows 10 22H2 и Windows 11.

Тесты `IPList.Core.Tests` используют только локальные фикстуры с зарезервированными для документации IP-адресами и фальшивыми ключами. Они не обращаются к сети и не требуют WPF или активного VPN-профиля.
