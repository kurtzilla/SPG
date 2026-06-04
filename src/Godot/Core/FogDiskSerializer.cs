using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Godot;

namespace SPG.Godot.Core;

/// <summary>
/// Crash-resilient, schema-agnostic fog state file I/O. Saves only on explicit demand.
/// </summary>
public partial class FogDiskSerializer : Node
{
    private const string UserSaveUri = "user://fog_state_raw.json";

    private readonly SemaphoreSlim _saveGate = new(1, 1);

    private string _masterPath = "";
    private string _tempPath = "";
    private bool _pathsResolved;

    public override void _Ready() => EnsurePathsResolved();

    public override void _ExitTree() => _saveGate.Dispose();

    /// <summary>
    /// Processes serialized chunk payloads asynchronously.
    /// Accepts Godot params-array marshaling (Variant[]) from GDScript call sites.
    /// </summary>
    public async Task<bool> SaveStateExplicitAsync(Variant[] args)
    {
        if (args == null || args.Length == 0)
        {
            GD.PrintErr("FogDiskSerializer: No payload arguments provided.");
            return false;
        }

        string serializedPayload = args[0].As<string>();
        if (string.IsNullOrEmpty(serializedPayload))
            return false;

        EnsurePathsResolved();
        await _saveGate.WaitAsync();
        try
        {
            var directory = Path.GetDirectoryName(_masterPath);
            if (!string.IsNullOrEmpty(directory))
                Directory.CreateDirectory(directory);

            await File.WriteAllTextAsync(_tempPath, serializedPayload, Encoding.UTF8);

            if (File.Exists(_masterPath))
                File.Replace(_tempPath, _masterPath, destinationBackupFileName: null);
            else
                File.Move(_tempPath, _masterPath);

            return true;
        }
        catch (Exception ex)
        {
            TryDeleteTempFile();
            GD.PrintErr($"FogDiskSerializer: save failed — {ex.Message}");
            return false;
        }
        finally
        {
            _saveGate.Release();
        }
    }

    public string LoadStateFromDisk()
    {
        EnsurePathsResolved();
        if (!File.Exists(_masterPath))
            return "";

        try
        {
            return File.ReadAllText(_masterPath, Encoding.UTF8);
        }
        catch (Exception ex)
        {
            GD.PrintErr($"FogDiskSerializer: load failed — {ex.Message}");
            return "";
        }
    }

    public async Task<string> LoadStateFromDiskAsync()
    {
        EnsurePathsResolved();
        if (!File.Exists(_masterPath))
            return "";

        try
        {
            return await File.ReadAllTextAsync(_masterPath, Encoding.UTF8);
        }
        catch (Exception ex)
        {
            GD.PrintErr($"FogDiskSerializer: load failed — {ex.Message}");
            return "";
        }
    }

    private void EnsurePathsResolved()
    {
        if (_pathsResolved)
            return;

        _masterPath = ProjectSettings.GlobalizePath(UserSaveUri);
        _tempPath = _masterPath + ".tmp";
        _pathsResolved = true;
    }

    private void TryDeleteTempFile()
    {
        try
        {
            if (File.Exists(_tempPath))
                File.Delete(_tempPath);
        }
        catch
        {
            // Best-effort cleanup after a failed save.
        }
    }
}