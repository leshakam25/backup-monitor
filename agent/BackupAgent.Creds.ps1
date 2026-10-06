# Сетевые учётные данные — в Диспетчере учётных данных Windows (не в наших файлах).
# Задания работают от SYSTEM, поэтому записи кладутся в хранилище SYSTEM: Windows сама подставит их
# при обращении к \\сервер\... Запись в хранилище SYSTEM делает Install-Agent.ps1 через разовую задачу
# Планировщика от SYSTEM (Invoke-AsSystem).

function Get-UncHost {
    # \\192.168.1.10\backup\1C -> 192.168.1.10 ; не UNC -> $null
    param([string]$Path)
    if ($Path -match '^\\\\([^\\]+)') { return $Matches[1] }
    return $null
}

function Initialize-CredApi {
    if ('BackupAgent.CredStore' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace BackupAgent {
public static class CredStore {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob;
        public int Persist; public int AttributeCount; public IntPtr Attributes;
        public string TargetAlias; public string UserName;
    }
    const int CRED_TYPE_DOMAIN_PASSWORD = 2;   // «учётные данные Windows»: их использует SMB
    const int CRED_PERSIST_LOCAL_MACHINE = 2;

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWrite(ref CREDENTIAL cred, int flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDelete(string target, int type, int flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredEnumerate(string filter, int flags, out int count, out IntPtr creds);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr buffer);

    public static void Write(string target, string user, string password) {
        var c = new CREDENTIAL();
        c.Type = CRED_TYPE_DOMAIN_PASSWORD; c.TargetName = target; c.UserName = user;
        c.Persist = CRED_PERSIST_LOCAL_MACHINE;
        c.CredentialBlob = Marshal.StringToCoTaskMemUni(password);
        c.CredentialBlobSize = password.Length * 2;
        try {
            if (!CredWrite(ref c, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        } finally { Marshal.ZeroFreeCoTaskMemUnicode(c.CredentialBlob); }
    }

    public static bool Delete(string target) { return CredDelete(target, CRED_TYPE_DOMAIN_PASSWORD, 0); }

    // "цель|пользователь" для всех учётных данных Windows (без паролей)
    public static string[] List() {
        var result = new List<string>();
        int count; IntPtr p;
        if (!CredEnumerate(null, 0, out count, out p)) return result.ToArray();
        try {
            for (int i = 0; i < count; i++) {
                var c = (CREDENTIAL)Marshal.PtrToStructure(Marshal.ReadIntPtr(p, i * IntPtr.Size), typeof(CREDENTIAL));
                if (c.Type == CRED_TYPE_DOMAIN_PASSWORD) result.Add(c.TargetName + "|" + c.UserName);
            }
        } finally { CredFree(p); }
        return result.ToArray();
    }
}
}
'@
}

function Get-AccessHint {
    # Подсказка к ошибке доступа к сетевому пути
    param([string]$Path)
    $h = Get-UncHost $Path
    if (-not $h) { return '' }
    return " — если нужен логин/пароль, сохраните их: Install.cmd -Credential \\$h"
}
