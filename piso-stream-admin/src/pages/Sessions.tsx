import React from 'react';
import { useStore } from '../store/useStore';
import { Users } from 'lucide-react';
import { motion } from 'motion/react';

export default function Sessions() {
  const { sessions, kiosks, loadSessions } = useStore();

  React.useEffect(() => {
    loadSessions();
    const intervalId = window.setInterval(() => {
      loadSessions();
    }, 5000);

    return () => {
      window.clearInterval(intervalId);
    };
  }, [loadSessions]);

  const getKioskName = (id: string) => kiosks.find(k => k.id === id)?.name || 'Unknown';

  const formatTime = (seconds: number) => {
    const min = Math.floor(seconds / 60);
    const sec = seconds % 60;
    return `${min}:${sec.toString().padStart(2, '0')}`;
  };

  return (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-2 duration-500">
      <div>
        <h2 className="text-xl font-bold tracking-tight text-[#09090B]">Live Sessions</h2>
        <p className="text-[10px] text-[#71717A] uppercase tracking-widest font-semibold mt-1">Real-time user engagement metrics</p>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {sessions.length === 0 ? (
          <div className="col-span-full py-20 text-center bg-white border border-[#E4E4E7]">
            <Users className="w-10 h-10 text-[#E4E4E7] mx-auto mb-4" />
            <p className="text-[10px] font-bold text-[#A1A1AA] uppercase tracking-widest">No active sessions detected</p>
          </div>
        ) : (
          sessions.map((session) => (
            <motion.div 
              layout
              key={session.id}
              className="bg-white border border-[#E4E4E7] flex flex-col"
            >
              <div className="p-6 border-b border-[#F4F4F5]">
                <div className="flex items-center justify-between mb-1">
                  <h3 className="text-xs font-bold uppercase tracking-widest text-[#18181B]">{session.userName}</h3>
                  <span className="text-[10px] font-bold text-emerald-600 bg-emerald-50 px-2 py-0.5 border border-emerald-100 uppercase tracking-tighter">Live</span>
                </div>
                <p className="text-[10px] text-[#71717A] font-medium uppercase tracking-tight">Connected via {getKioskName(session.kioskId).toUpperCase()}</p>
              </div>

              <div className="p-6 space-y-6">
                <div className="flex flex-col items-center justify-center py-4 bg-[#F4F4F5]">
                  <p className="text-[10px] font-bold text-[#A1A1AA] uppercase tracking-[0.2em] mb-1">Remaining</p>
                  <span className="text-4xl font-light tracking-tighter text-[#18181B] tabular-nums">
                    {formatTime(session.timeLeft)}
                  </span>
                </div>

                <div className="grid grid-cols-2 gap-px bg-[#E4E4E7]">
                  <div className="bg-white p-3">
                    <p className="text-[9px] font-bold text-[#A1A1AA] uppercase tracking-widest mb-1">Revenue</p>
                    <p className="text-sm font-light text-[#18181B]">₱{session.totalSpent.toFixed(2)}</p>
                  </div>
                  <div className="bg-white p-3">
                    <p className="text-[9px] font-bold text-[#A1A1AA] uppercase tracking-widest mb-1">Uptime</p>
                    <p className="text-sm font-light text-[#18181B]">
                      {new Date(session.startTime).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                    </p>
                  </div>
                </div>
              </div>

              <div className="p-4 bg-[#FAFAFA] border-t border-[#F4F4F5]">
                <button className="w-full py-2 bg-white border border-[#E4E4E7] text-[#18181B] text-[10px] font-bold uppercase tracking-widest hover:bg-[#18181B] hover:text-white transition-all cursor-pointer">
                  Disconnect Session
                </button>
              </div>
            </motion.div>
          ))
        )}
      </div>
    </div>
  );
}
