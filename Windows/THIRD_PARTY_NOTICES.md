# Third-party notices

Windows IPList includes the MIT-licensed metadata snapshot from
[pincetgore/amnezia-app-ru-list](https://github.com/pincetgore/amnezia-app-ru-list).
The corresponding license text is bundled in `src/IPList.Core/Resources/ThirdParty/pincetgore-LICENSE`.

The lib4u address lists are downloaded at runtime and are not redistributed in
the repository or in the Windows package.

The Windows CI package is a self-contained .NET 10 application for `win-x64`.
It includes the .NET runtime components required to run without a separately
installed .NET runtime. Those components are distributed under Microsoft's
applicable .NET runtime terms. NuGet packages used only by the test project and
the sanitized test fixtures are not included in the application package.
