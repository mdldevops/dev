import React, { useEffect, useState } from 'react';
import { useStore } from '../store/useStore';

const API_BASE_URL =
  import.meta.env.VITE_API_BASE_URL?.trim() ||
  (typeof window !== 'undefined' ? window.location.origin : 'http://192.168.1.7:523');

export default function Settings() {
  const { settings, updateSettings, broadcast } = useStore();
  const [localRatios, setLocalRatios] = useState(settings.ratios);
  const [message, setMessage] = useState('');
  const [isSaving, setIsSaving] = useState(false);
  const [saveMessage, setSaveMessage] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [isBroadcasting, setIsBroadcasting] = useState(false);
  const [broadcastSuccess, setBroadcastSuccess] = useState<string | null>(null);
  const [broadcastFailure, setBroadcastFailure] = useState<string | null>(null);
  const [audioEnabled, setAudioEnabled] = useState(false);
  const [audioUrl, setAudioUrl] = useState('');
  const [audioLoop, setAudioLoop] = useState(true);
  const [audioVolume, setAudioVolume] = useState(1.0);
  const [isLoadingAudio, setIsLoadingAudio] = useState(true);
  const [isAudioSaving, setIsAudioSaving] = useState(false);
  const [audioSaveMessage, setAudioSaveMessage] = useState<string | null>(null);
  const [audioSaveError, setAudioSaveError] = useState<string | null>(null);
  const [audioFile, setAudioFile] = useState<File | null>(null);

  useEffect(() => {
    setLocalRatios(settings.ratios);
  }, [settings.ratios]);

  useEffect(() => {
    fetchAudioSettings();
  }, []);

  const fetchAudioSettings = async () => {
    try {
      setIsLoadingAudio(true);
      const response = await fetch(`${API_BASE_URL}/settings/audio-config`);
      if (response.ok) {
        const data = await response.json();
        if (data.success && data.audio) {
          setAudioEnabled(data.audio.audioEnabled || false);
          setAudioUrl(data.audio.audioUrl || '');
          setAudioLoop(data.audio.audioLoop !== false);
          setAudioVolume(data.audio.audioVolume || 1.0);
        }
      }
    } catch (error) {
      console.error('Failed to fetch audio settings:', error);
    } finally {
      setIsLoadingAudio(false);
    }
  };

  const handleUpdateRatio = (
    key: keyof typeof settings.ratios,
    value: string,
  ) => {
    const nextValue = Math.max(0, parseInt(value, 10) || 0);
    setLocalRatios((prev) => ({ ...prev, [key]: nextValue }));
  };

  const handleSaveRatio = async () => {
    setIsSaving(true);
    setSaveMessage(null);
    setSaveError(null);

    const didSave = await updateSettings({ ratios: localRatios });
    if (didSave) {
      setSaveMessage('Successfully saved coin-to-time ratios.');
    } else {
      setSaveError('Unable to save ratios. Please check the server connection.');
    }

    setIsSaving(false);
  };

  const handleSaveAudioSettings = async () => {
    setIsAudioSaving(true);
    setAudioSaveMessage(null);
    setAudioSaveError(null);

    try {
      const response = await fetch(`${API_BASE_URL}/settings/audio-config`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          audioEnabled,
          audioUrl,
          audioLoop,
          audioVolume,
        }),
      });

      if (response.ok) {
        const data = await response.json();
        if (data.success) {
          setAudioSaveMessage('Audio settings updated successfully.');
        } else {
          setAudioSaveError('Failed to update audio settings.');
        }
      } else {
        setAudioSaveError('Server error. Please try again.');
      }
    } catch (error) {
      console.error('Audio settings save error:', error);
      setAudioSaveError('Unable to save audio settings. Please check the server connection.');
    } finally {
      setIsAudioSaving(false);
    }
  };

  const handleAudioFileSelect = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (file) {
      setAudioFile(file);
      // In a real implementation, you would upload this file to the server
      // For now, we'll use a data URL or file path
      const reader = new FileReader();
      reader.onload = (e) => {
        const url = e.target?.result as string;
        setAudioUrl(url);
      };
      reader.readAsDataURL(file);
    }
  };

  const handleBroadcast = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!message.trim()) {
      return;
    }

    setIsBroadcasting(true);
    setBroadcastSuccess(null);
    setBroadcastFailure(null);

    const didSend = await broadcast(message);
    if (didSend) {
      setMessage('');
      setBroadcastSuccess('Broadcast message sent successfully.');
    } else {
      setBroadcastFailure(
        'Unable to send broadcast. Please check the server connection.',
      );
    }

    setIsBroadcasting(false);
  };

  const p1Base = Math.max(localRatios.p1 * 20, 1);
  const bonusPercent = Math.round((localRatios.p20 / p1Base - 1) * 100);
  const commandLog = [
    { action: 'RATIO_ADJUST', detail: 'Changed to 6m/₱1', time: '10:42 AM' },
    {
      action: 'BROADCAST_PULSE',
      detail: '"System update scheduled"',
      time: '09:15 AM',
    },
  ];

  return (
    <div className="max-w-4xl space-y-8 animate-in fade-in slide-in-from-bottom-2 duration-500">
      <div>
        <h2 className="text-xl font-bold tracking-tight text-[#09090B]">
          Configuration Panel
        </h2>
        <p className="mt-1 text-[10px] font-semibold uppercase tracking-widest text-[#71717A]">
          System parameters and node control
        </p>
      </div>

      <div className="grid grid-cols-1 gap-8 md:grid-cols-2">
        <section className="space-y-6 border border-[#E4E4E7] bg-white p-8">
          <div>
            <h3 className="text-xs font-bold uppercase tracking-[0.2em] text-[#18181B]">
              Coin-to-Time Flow
            </h3>
          </div>

          <p className="text-[11px] font-medium leading-relaxed text-[#71717A]">
            Define system-wide minute values per currency unit. All connected
            nodes will sync immediately.
          </p>

          <div className="space-y-4">
            {[
              { key: 'p1', label: '₱1.00 Value' },
              { key: 'p5', label: '₱5.00 Value' },
              { key: 'p10', label: '₱10.00 Value' },
              { key: 'p20', label: '₱20.00 Value' },
            ].map((item) => (
              <div
                key={item.key}
                className="group flex items-center justify-between"
              >
                <label className="text-[11px] font-semibold uppercase tracking-widest text-[#18181B]">
                  {item.label}
                </label>
                <div className="flex items-center gap-2">
                  <input
                    type="number"
                    value={localRatios[item.key as keyof typeof localRatios]}
                    onChange={(e) =>
                      handleUpdateRatio(
                        item.key as keyof typeof settings.ratios,
                        e.target.value,
                      )
                    }
                    className="w-16 rounded-sm bg-[#F4F4F5] py-2 text-center text-xs font-bold outline-none focus:ring-1 focus:ring-[#18181B]"
                  />
                  <span className="text-[10px] font-bold text-[#A1A1AA]">
                    MINS
                  </span>
                </div>
              </div>
            ))}

            <button
              onClick={handleSaveRatio}
              disabled={isSaving}
              className="mt-4 w-full cursor-pointer rounded-sm bg-[#18181B] py-3 text-[10px] font-bold uppercase tracking-widest text-white transition-colors hover:bg-black disabled:opacity-50"
            >
              {isSaving ? 'Updating...' : 'Update Ratios'}
            </button>
            {saveMessage ? (
              <p className="text-[10px] font-bold uppercase tracking-widest text-emerald-600">
                {saveMessage}
              </p>
            ) : null}
            {saveError ? (
              <p className="text-[10px] font-bold uppercase tracking-widest text-red-600">
                {saveError}
              </p>
            ) : null}

            <div className="border border-[#F4F4F5] bg-[#FAFAFA] p-4">
              <div className="flex items-center justify-between text-[10px] font-bold uppercase tracking-tighter">
                <span className="text-[#A1A1AA]">Current Efficiency:</span>
                <span className="text-[#18181B]">
                  ₱20 provides {bonusPercent}% bonus
                </span>
              </div>
            </div>
          </div>
        </section>

        <section className="space-y-6 border border-[#E4E4E7] bg-white p-8">
          <div>
            <h3 className="text-xs font-bold uppercase tracking-[0.2em] text-[#18181B]">
              Pulse Emergency
            </h3>
          </div>

          <p className="text-[11px] font-medium leading-relaxed text-[#71717A]">
            Send a high-priority system overlay message to all active terminal
            sessions.
          </p>

          <form onSubmit={handleBroadcast} className="space-y-4">
            <div>
              <label className="mb-2 block text-[10px] font-bold uppercase tracking-widest text-[#A1A1AA]">
                Payload Message
              </label>
              <textarea
                rows={3}
                placeholder="e.g., Maintenance window approaching..."
                value={message}
                onChange={(e) => setMessage(e.target.value)}
                className="w-full resize-none rounded-sm bg-[#F4F4F5] px-4 py-3 text-xs outline-none placeholder:text-[#A1A1AA] focus:ring-1 focus:ring-[#18181B]"
              />
            </div>

            <button
              type="submit"
              disabled={isBroadcasting || !message.trim()}
              className="w-full cursor-pointer border border-[#18181B] bg-white py-3 text-[10px] font-bold uppercase tracking-widest text-[#18181B] transition-all hover:bg-[#18181B] hover:text-white disabled:cursor-not-allowed disabled:opacity-50"
            >
              {isBroadcasting ? 'Transmitting...' : 'Send Pulse Message'}
            </button>
            {broadcastSuccess ? (
              <p className="text-[10px] font-bold uppercase tracking-widest text-emerald-600">
                {broadcastSuccess}
              </p>
            ) : null}
            {broadcastFailure ? (
              <p className="text-[10px] font-bold uppercase tracking-widest text-red-600">
                {broadcastFailure}
              </p>
            ) : null}
          </form>
        </section>

        <section className="md:col-span-2 space-y-6 border border-[#E4E4E7] bg-white p-8">
          <div>
            <h3 className="text-xs font-bold uppercase tracking-[0.2em] text-[#18181B]">
              Audio Configuration
            </h3>
          </div>

          <p className="text-[11px] font-medium leading-relaxed text-[#71717A]">
            Configure background audio for arcade sessions. Enable audio playback and set looping and volume.
          </p>

          {isLoadingAudio ? (
            <div className="flex items-center justify-center py-4">
              <span className="text-[11px] text-[#71717A]">Loading audio settings...</span>
            </div>
          ) : (
            <div className="space-y-4">
              <div className="flex items-center justify-between">
                <label className="text-[11px] font-semibold uppercase tracking-widest text-[#18181B]">
                  Enable Audio
                </label>
                <input
                  type="checkbox"
                  checked={audioEnabled}
                  onChange={(e) => setAudioEnabled(e.target.checked)}
                  className="h-4 w-4 cursor-pointer"
                />
              </div>

              <div>
                <label className="mb-2 block text-[10px] font-bold uppercase tracking-widest text-[#A1A1AA]">
                  Audio File URL
                </label>
                <input
                  type="text"
                  value={audioUrl}
                  onChange={(e) => setAudioUrl(e.target.value)}
                  placeholder="e.g., http://example.com/audio.mp3 or /path/to/audio.mp3"
                  className="w-full rounded-sm bg-[#F4F4F5] px-4 py-3 text-xs outline-none placeholder:text-[#A1A1AA] focus:ring-1 focus:ring-[#18181B]"
                />
              </div>

              <div>
                <label className="mb-2 block text-[10px] font-bold uppercase tracking-widest text-[#A1A1AA]">
                  Or Browse Audio File
                </label>
                <input
                  type="file"
                  accept="audio/*"
                  onChange={handleAudioFileSelect}
                  className="w-full cursor-pointer rounded-sm bg-[#F4F4F5] px-4 py-3 text-xs outline-none focus:ring-1 focus:ring-[#18181B]"
                />
              </div>

              <div className="flex items-center justify-between">
                <label className="text-[11px] font-semibold uppercase tracking-widest text-[#18181B]">
                  Loop Audio
                </label>
                <input
                  type="checkbox"
                  checked={audioLoop}
                  onChange={(e) => setAudioLoop(e.target.checked)}
                  className="h-4 w-4 cursor-pointer"
                />
              </div>

              <div>
                <label className="mb-2 block text-[11px] font-semibold uppercase tracking-widest text-[#18181B]">
                  Volume: {Math.round(audioVolume * 100)}%
                </label>
                <input
                  type="range"
                  min="0"
                  max="1"
                  step="0.1"
                  value={audioVolume}
                  onChange={(e) => setAudioVolume(parseFloat(e.target.value))}
                  className="w-full cursor-pointer"
                />
              </div>

              <button
                onClick={handleSaveAudioSettings}
                disabled={isAudioSaving}
                className="mt-4 w-full cursor-pointer rounded-sm bg-[#18181B] py-3 text-[10px] font-bold uppercase tracking-widest text-white transition-colors hover:bg-black disabled:opacity-50"
              >
                {isAudioSaving ? 'Saving...' : 'Save Audio Settings'}
              </button>
              {audioSaveMessage ? (
                <p className="text-[10px] font-bold uppercase tracking-widest text-emerald-600">
                  {audioSaveMessage}
                </p>
              ) : null}
              {audioSaveError ? (
                <p className="text-[10px] font-bold uppercase tracking-widest text-red-600">
                  {audioSaveError}
                </p>
              ) : null}
            </div>
          )}
        </section>

        <section className="md:col-span-2 border border-[#E4E4E7] bg-[#FAFAFA] p-8">
          <div className="mb-8 flex items-center justify-between">
            <div>
              <h3 className="text-xs font-bold uppercase tracking-[0.2em] text-[#18181B]">
                System Command Log
              </h3>
            </div>
            <button className="cursor-pointer text-[10px] font-bold uppercase tracking-widest text-[#EF4444] hover:underline">
              Purge Data
            </button>
          </div>

          <div className="space-y-2">
            {commandLog.map((log) => (
              <div
                key={`${log.action}-${log.time}`}
                className="flex items-center justify-between border-b border-[#E4E4E7]/30 py-2"
              >
                <div className="flex items-center gap-4">
                  <span className="border border-[#E4E4E7] bg-white px-2 py-0.5 font-mono text-[10px] font-bold text-[#18181B]">
                    {log.action}
                  </span>
                  <span className="text-[11px] font-medium text-[#71717A]">
                    {log.detail}
                  </span>
                </div>
                <span className="font-mono text-[10px] text-[#A1A1AA]">
                  {log.time}
                </span>
              </div>
            ))}
          </div>
        </section>
      </div>
    </div>
  );
}
