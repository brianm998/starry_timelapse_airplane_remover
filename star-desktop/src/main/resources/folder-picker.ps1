# Explorer's folder picker (IFileOpenDialog with FOS_PICKFOLDERS), run by star-desktop's FolderPickers.kt.
# Input: STAR_TITLE and STAR_START in the environment (not interpolated, so quoting cannot break it).
# Output: the chosen folder on stdout (UTF-8). Exit 0 chosen, 1 cancelled, 2 failed.
$ErrorActionPreference = 'Stop'
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class StarFolderPicker {
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    private class FileOpenDialogClass { }

    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileDialog {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint count, IntPtr types);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem item);
        void SetFolder(IShellItem item);
        void GetFolder(out IShellItem item);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetResult(out IShellItem item);
    }

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem item);
        void GetDisplayName(uint sigdn, [MarshalAs(UnmanagedType.LPWStr)] out string name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(
        [MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr bindContext,
        [MarshalAs(UnmanagedType.LPStruct)] Guid iid, out IShellItem item);

    private const uint FOS_PICKFOLDERS = 0x20, FOS_FORCEFILESYSTEM = 0x40, FOS_PATHMUSTEXIST = 0x800;
    private const uint SIGDN_FILESYSPATH = 0x80058000;
    private const int CANCELLED = unchecked((int)0x800704C7);

    // The chosen folder, or null when the user cancelled.
    public static string Pick(string title, string start) {
        IFileDialog dialog = (IFileDialog)new FileOpenDialogClass();
        uint options;
        dialog.GetOptions(out options);
        dialog.SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
        if (!String.IsNullOrEmpty(title)) dialog.SetTitle(title);
        if (!String.IsNullOrEmpty(start)) {
            try {
                IShellItem folder;
                SHCreateItemFromParsingName(start, IntPtr.Zero, new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), out folder);
                dialog.SetFolder(folder);
            } catch (COMException) { }
        }
        int hr = dialog.Show(IntPtr.Zero);
        if (hr == CANCELLED) return null;
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        IShellItem result;
        dialog.GetResult(out result);
        string path;
        result.GetDisplayName(SIGDN_FILESYSPATH, out path);
        return path;
    }
}
'@
    $path = [StarFolderPicker]::Pick($env:STAR_TITLE, $env:STAR_START)
    if ($null -eq $path) { exit 1 }
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::Out.WriteLine($path)
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
