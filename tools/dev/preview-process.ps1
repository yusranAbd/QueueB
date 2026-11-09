# Dot-source only. Initializing the type does not start a process or change env.
function Initialize-QueueBPreviewProcessType {
    if ('QueueBRemotePreview.ProcessGroup' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace QueueBRemotePreview {
    public static class NativeArguments {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CommandLineToArgvW(string value, out int count);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr value);
        public static string[] Parse(string value) {
            if (String.IsNullOrWhiteSpace(value)) return new string[0];
            int count; IntPtr memory = CommandLineToArgvW(value, out count);
            if (memory == IntPtr.Zero) throw Native.Error("Argumen proses tidak dapat dibaca");
            try {
                string[] result = new string[count];
                for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, i * IntPtr.Size));
                return result;
            } finally { LocalFree(memory); }
        }
        internal static string Quote(string value) {
            if (value == null || value.IndexOf('\0') >= 0) throw new ArgumentException("Argumen proses tidak valid.");
            if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '\r', '\n', '\v', '\f', '"' }) < 0) return value;
            StringBuilder text = new StringBuilder("\""); int slashes = 0;
            foreach (char item in value) {
                if (item == '\\') { slashes++; continue; }
                text.Append('\\', item == '"' ? slashes * 2 + 1 : slashes);
                text.Append(item); slashes = 0;
            }
            text.Append('\\', slashes * 2); text.Append('"'); return text.ToString();
        }
    }

    public sealed class OwnedProcess {
        private readonly ProcessGroup owner;
        private IntPtr handle;
        public int Id { get; private set; }
        internal OwnedProcess(ProcessGroup group, IntPtr process, int id) { owner = group; handle = process; Id = id; }
        public bool HasExited {
            get { lock (this) {
                if (handle == IntPtr.Zero) throw new ObjectDisposedException("OwnedProcess");
                uint status = Native.WaitForSingleObject(handle, 0);
                if (status == 0xffffffff) throw Native.Error("Status proses tidak dapat dibaca");
                GC.KeepAlive(owner); return status == 0;
            } }
        }
        public int ExitCode {
            get { lock (this) {
                if (!HasExited) throw new InvalidOperationException("Proses masih berjalan.");
                uint code;
                if (!Native.GetExitCodeProcess(handle, out code)) throw Native.Error("Kode keluar proses tidak dapat dibaca");
                return unchecked((int)code);
            } }
        }
        internal void Close() { lock (this) { if (handle != IntPtr.Zero) { Native.CloseHandle(handle); handle = IntPtr.Zero; } } }
    }

    public sealed class ProcessGroup : IDisposable {
        private readonly object gate = new object();
        private readonly List<OwnedProcess> children = new List<OwnedProcess>();
        private IntPtr job;
        public ProcessGroup() {
            job = Native.CreateJobObjectW(IntPtr.Zero, null);
            if (job == IntPtr.Zero) throw Native.Error("Grup proses preview tidak dapat dibuat");
            Native.ExtendedLimits limits = new Native.ExtendedLimits();
            limits.BasicLimitInformation.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE; no breakaway.
            if (!Native.SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(Native.ExtendedLimits)))) {
                Exception failure = Native.Error("Batas grup proses preview tidak dapat ditetapkan");
                Native.CloseHandle(job); job = IntPtr.Zero; throw failure;
            }
        }
        private void EnsureOpen() { if (job == IntPtr.Zero) throw new ObjectDisposedException("ProcessGroup"); }
        public int ActiveProcessCount {
            get { lock (gate) {
                EnsureOpen(); Native.Accounting data;
                if (!Native.QueryInformationJobObject(job, 1, out data, (uint)Marshal.SizeOf(typeof(Native.Accounting)), IntPtr.Zero))
                    throw Native.Error("Jumlah proses preview tidak dapat dibaca");
                return checked((int)data.ActiveProcesses);
            } }
        }
        public bool HasActiveProcesses { get { return ActiveProcessCount > 0; } }
        public bool ContainsProcess(int processId) {
            lock (gate) {
                EnsureOpen(); if (processId <= 0) return false;
                IntPtr process = Native.OpenProcess(0x1000, false, processId);
                if (process == IntPtr.Zero) return false;
                try { bool member; return Native.IsProcessInJob(process, job, out member) && member; }
                finally { Native.CloseHandle(process); }
            }
        }
        public OwnedProcess Start(string executable, string[] arguments, string workingDirectory, string logPath) {
            lock (gate) {
                EnsureOpen();
                if (String.IsNullOrWhiteSpace(executable) || !Path.IsPathRooted(executable) || !File.Exists(executable))
                    throw new ArgumentException("Executable preview harus file absolut yang tersedia.");
                if (!Directory.Exists(workingDirectory)) throw new ArgumentException("Direktori proses preview tidak tersedia.");
                StringBuilder command = new StringBuilder(NativeArguments.Quote(Path.GetFullPath(executable)));
                foreach (string value in arguments ?? new string[0]) command.Append(' ').Append(NativeArguments.Quote(value));
                Native.SecurityAttributes security = new Native.SecurityAttributes();
                security.Length = Marshal.SizeOf(typeof(Native.SecurityAttributes)); security.InheritHandle = true;
                IntPtr log = new IntPtr(-1), input = new IntPtr(-1);
                Native.ProcessInformation info = new Native.ProcessInformation(); bool transferred = false;
                try {
                    // Discard agent output which may contain credential diagnostics.
                    bool discardOutput = String.Equals(logPath, "NUL", StringComparison.OrdinalIgnoreCase);
                    log = Native.CreateFileW(discardOutput ? "NUL" : Path.GetFullPath(logPath), discardOutput ? 0x40000000u : 4u,
                        3, ref security, discardOutput ? 3u : 4u, 0x80, IntPtr.Zero); // Append only for local logs.
                    if (log == new IntPtr(-1)) throw Native.Error("Log proses preview tidak dapat dibuka");
                    input = Native.CreateFileW("NUL", 0x80000000, 3, ref security, 3, 0x80, IntPtr.Zero);
                    if (input == new IntPtr(-1)) throw Native.Error("Input proses preview tidak dapat disiapkan");
                    Native.StartupInfo startup = new Native.StartupInfo();
                    startup.Size = Marshal.SizeOf(typeof(Native.StartupInfo)); startup.Flags = 0x100;
                    startup.StandardInput = input; startup.StandardOutput = log; startup.StandardError = log;
                    if (!Native.CreateProcessW(Path.GetFullPath(executable), command, IntPtr.Zero, IntPtr.Zero, true,
                        0x08000004, IntPtr.Zero, Path.GetFullPath(workingDirectory), ref startup, out info))
                        throw Native.Error("Proses preview tidak dapat dibuat");
                    // The primary thread cannot run or spawn children before job assignment.
                    if (!Native.AssignProcessToJobObject(job, info.Process)) throw Native.Error("Proses preview tidak dapat dimasukkan ke grup milik workflow");
                    if (Native.ResumeThread(info.Thread) == 0xffffffff) throw Native.Error("Proses preview tidak dapat dilanjutkan");
                    OwnedProcess child = new OwnedProcess(this, info.Process, info.ProcessId);
                    children.Add(child); transferred = true; return child;
                } finally {
                    if (info.Process != IntPtr.Zero && !transferred) { Native.TerminateProcess(info.Process, 1); Native.CloseHandle(info.Process); }
                    if (info.Thread != IntPtr.Zero) Native.CloseHandle(info.Thread);
                    if (log != new IntPtr(-1)) Native.CloseHandle(log);
                    if (input != new IntPtr(-1)) Native.CloseHandle(input);
                }
            }
        }
        public void Dispose() {
            lock (gate) {
                if (job != IntPtr.Zero) { Native.CloseHandle(job); job = IntPtr.Zero; }
                foreach (OwnedProcess child in children) child.Close(); children.Clear();
            }
            GC.SuppressFinalize(this);
        }
        ~ProcessGroup() { Dispose(); }
    }

    internal static class Native {
        internal static Exception Error(string label) { int code = Marshal.GetLastWin32Error(); return new InvalidOperationException(label + " (Win32 " + code + ")."); }
        [StructLayout(LayoutKind.Sequential)] internal struct SecurityAttributes { internal int Length; internal IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] internal bool InheritHandle; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct StartupInfo {
            internal int Size; internal string Reserved, Desktop, Title;
            internal uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
            internal ushort ShowWindow, ReservedSize; internal IntPtr ReservedBytes, StandardInput, StandardOutput, StandardError;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct ProcessInformation { internal IntPtr Process, Thread; internal int ProcessId, ThreadId; }
        [StructLayout(LayoutKind.Sequential)] internal struct BasicLimits {
            internal long ProcessTime, JobTime; internal uint LimitFlags;
            internal UIntPtr MinWorkingSet, MaxWorkingSet; internal uint ActiveProcessLimit;
            internal UIntPtr Affinity; internal uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct IoCounters { internal ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] internal struct ExtendedLimits { internal BasicLimits BasicLimitInformation; internal IoCounters IoInfo; internal UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
        [StructLayout(LayoutKind.Sequential)] internal struct Accounting { internal long UserTime, KernelTime, PeriodUserTime, PeriodKernelTime; internal uint PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetInformationJobObject(IntPtr job, int type, ref ExtendedLimits value, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool QueryInformationJobObject(IntPtr job, int type, out Accounting value, uint length, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsProcessInJob(IntPtr process, IntPtr job, [MarshalAs(UnmanagedType.Bool)] out bool result);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, int processId);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern IntPtr CreateFileW(string path, uint access, uint sharing, ref SecurityAttributes security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CreateProcessW(string application, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation process);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CloseHandle(IntPtr handle);
    }
}
'@ -ErrorAction Stop
}
