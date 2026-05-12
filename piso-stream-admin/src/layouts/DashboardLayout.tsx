import React, { useState } from 'react';
import { Outlet, Navigate } from 'react-router-dom';
import Sidebar from '../components/Sidebar';
import { useStore } from '../store/useStore';
import { motion } from 'motion/react';

export default function DashboardLayout() {
  const isAuthenticated = useStore((state) => state.isAuthenticated);
  const broadcastMessage = useStore((state) => state.settings.broadcastMessage);
  const broadcast = useStore((state) => state.broadcast);
  const selectedDeviceIds = useStore((state) => state.selectedDeviceIds);
  const [draftMessage, setDraftMessage] = useState('');
  const [broadcastTarget, setBroadcastTarget] = useState<'all' | 'selected'>('all');

  const hasSelectedTargets = selectedDeviceIds.length > 0;
  const canSend =
    draftMessage.trim().length > 0 &&
    (broadcastTarget === 'all' || hasSelectedTargets);

  const handleBroadcast = async () => {
    const normalizedMessage = draftMessage.trim();
    if (!normalizedMessage) {
      return;
    }

    const targets = broadcastTarget === 'selected' ? selectedDeviceIds : [];
    if (broadcastTarget === 'selected' && targets.length === 0) {
      return;
    }

    const didSend = await broadcast(normalizedMessage, targets);
    if (didSend) {
      setDraftMessage('');
    }
  };

  if (!isAuthenticated) {
    return <Navigate to="/login" replace />;
  }

  return (
    <div className="min-h-screen bg-[#F4F4F5] flex">
      <Sidebar />
      
      <main className="flex-1 ml-60 min-h-screen flex flex-col h-full overflow-hidden">
        {/* Top Bar / Global Broadcast */}
        <header className="h-16 border-b border-[#E4E4E7] bg-white flex items-center justify-between px-8 shrink-0 fixed top-0 right-0 left-60 z-20">
          <div className="flex items-center gap-4 w-full max-w-2xl">
            <span className="text-[10px] font-bold text-[#A1A1AA] uppercase tracking-tighter shrink-0">Broadcast:</span>
            <select
              value={broadcastTarget}
              onChange={(e) => setBroadcastTarget(e.target.value as 'all' | 'selected')}
              className="bg-[#F4F4F5] border-none text-xs px-3 py-2 rounded-sm focus:ring-1 focus:ring-[#18181B] outline-none"
            >
              <option value="all">All Devices</option>
              <option value="selected">Selected Devices</option>
            </select>
            <input 
              type="text" 
              placeholder="Enter global message for all kiosks..." 
              value={draftMessage}
              onChange={(e) => setDraftMessage(e.target.value)}
              className="w-full bg-[#F4F4F5] border-none text-sm px-4 py-2 rounded-sm focus:ring-1 focus:ring-[#18181B] placeholder:text-[#A1A1AA] outline-none"
              onKeyDown={async (e) => {
                if (e.key === 'Enter') {
                  await handleBroadcast();
                }
              }}
            />
            <button 
              onClick={handleBroadcast}
              disabled={!canSend}
              className="bg-[#18181B] text-white text-xs px-4 py-2 rounded-sm font-medium whitespace-nowrap active:scale-95 transition-transform cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
            >
              Send Pulse
            </button>
          </div>
          <div className="flex items-center gap-6 ml-4">
            <div className="flex flex-col items-end">
              <span className="text-[10px] text-[#A1A1AA] font-bold uppercase">Server Status</span>
              <span className="text-xs font-semibold text-emerald-600">
                {broadcastTarget === 'selected'
                  ? `${selectedDeviceIds.length} selected`
                  : 'All devices'}
              </span>
              {broadcastTarget === 'selected' && !hasSelectedTargets ? (
                <span className="text-[10px] text-amber-600 font-medium">
                  Pick at least one device
                </span>
              ) : null}
            </div>
          </div>
        </header>

        {/* Content */}
        <div className="mt-16 p-8 flex-1 overflow-auto">
          {broadcastMessage && (
             <motion.div 
               initial={{ opacity: 0, y: -10 }}
               animate={{ opacity: 1, y: 0 }}
               className="mb-8 p-3 bg-[#18181B] text-white text-xs font-medium rounded-sm flex items-center justify-between"
             >
                <div className="flex items-center gap-2">
                  <div className="w-1.5 h-1.5 bg-brand-50 rounded-full animate-pulse"></div>
                  <span>ACTIVE BROADCAST: {broadcastMessage}</span>
                </div>
                <span className="opacity-50 text-[10px] uppercase tracking-widest">Broadcasting pulse...</span>
             </motion.div>
          )}
          <Outlet />
        </div>
      </main>
    </div>
  );
}
