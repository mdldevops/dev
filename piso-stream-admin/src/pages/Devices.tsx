import React, { useEffect } from 'react';
import { useStore } from '../store/useStore';
import { MoreVertical, Search } from 'lucide-react';
import { motion } from 'motion/react';
import { Menu, Transition } from '@headlessui/react';

export default function Devices() {
  const {
    kiosks,
    loadDevices,
    setDeviceLock,
    toggleSelectedDevice,
    clearSelectedDevices,
  } = useStore();
  const [searchTerm, setSearchTerm] = React.useState('');

  useEffect(() => {
    loadDevices();
    const intervalId = window.setInterval(() => {
      loadDevices();
    }, 5000);

    return () => {
      window.clearInterval(intervalId);
    };
  }, [loadDevices]);

  const formatSessionValue = (
    remainingSeconds?: number,
    isSessionActive?: boolean,
  ) => {
    if (!isSessionActive) {
      return '--';
    }

    const totalSeconds = Math.max(0, remainingSeconds ?? 0);
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    return `${minutes.toString().padStart(2, '0')}:${seconds
      .toString()
      .padStart(2, '0')}`;
  };

  const normalizedSearch = searchTerm.trim().toLowerCase();
  const filteredKiosks = kiosks.filter((kiosk) => {
    if (!normalizedSearch) {
      return true;
    }

    const searchableValue = [
      kiosk.id,
      kiosk.name,
      kiosk.username,
      kiosk.ipAddress,
      kiosk.status,
    ]
      .join(' ')
      .toLowerCase();

    return searchableValue.includes(normalizedSearch);
  });

  return (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-2 duration-500">
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h2 className="text-xl font-bold tracking-tight text-[#09090B]">Device Management</h2>
          <p className="text-[10px] text-[#71717A] uppercase tracking-widest font-semibold mt-1">Status and connectivity monitoring</p>
        </div>
        <div className="flex items-center gap-3">
          <button
            onClick={clearSelectedDevices}
            className="px-3 py-2 bg-white border border-[#E4E4E7] rounded-sm text-[10px] font-bold text-[#71717A] uppercase tracking-widest hover:bg-[#FAFAFA] transition-colors cursor-pointer"
          >
            Clear Selected
          </button>
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-slate-400" />
            <input 
               type="text" 
               placeholder="Filter kiosks..." 
               value={searchTerm}
               onChange={(e) => setSearchTerm(e.target.value)}
               className="pl-9 pr-4 py-2 bg-white border border-[#E4E4E7] rounded-sm text-xs focus:ring-1 focus:ring-[#18181B] outline-none w-64 placeholder:text-[#A1A1AA]"
            />
          </div>
          <button className="flex items-center gap-3 px-4 py-2 bg-[#18181B] text-white rounded-sm text-xs font-medium hover:bg-black transition-colors cursor-pointer">
            <Search className="w-3 h-3" />
            Find Node
          </button>
        </div>
      </div>

      <div className="bg-white border border-[#E4E4E7] flex flex-col overflow-hidden">
        <div className="p-4 border-b border-[#F4F4F5] flex justify-between items-center bg-white">
          <h3 className="text-[10px] font-bold uppercase tracking-widest text-[#18181B]">Active Kiosk Status</h3>
          <span className="text-[10px] text-[#71717A] font-medium">SHOWING {filteredKiosks.length} OF {kiosks.length} NODES</span>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-left">
            <thead className="bg-[#FAFAFA] text-[10px] uppercase text-[#71717A] border-b border-[#F4F4F5]">
              <tr>
                <th className="px-6 py-4 font-bold tracking-wider">Pick</th>
                <th className="px-6 py-4 font-bold tracking-wider">Device ID</th>
                <th className="px-6 py-4 font-bold tracking-wider">Status</th>
                <th className="px-6 py-4 font-bold tracking-wider">Username</th>
                <th className="px-6 py-4 font-bold tracking-wider">User IP</th>
                <th className="px-6 py-4 font-bold tracking-wider">Session Time</th>
                <th className="px-6 py-4 text-right">Actions</th>
              </tr>
            </thead>
            <tbody className="text-xs divide-y divide-[#F4F4F5]">
              {filteredKiosks.map((kiosk) => (
                <motion.tr 
                  layout
                  key={kiosk.id} 
                  className="hover:bg-[#FAFAFA] transition-colors group"
                >
                  <td className="px-6 py-5">
                    <input
                      type="checkbox"
                      checked={Boolean(kiosk.isSelected)}
                      onChange={() => toggleSelectedDevice(kiosk.id)}
                      className="w-4 h-4 accent-[#18181B] cursor-pointer"
                    />
                  </td>
                  <td className="px-6 py-5 font-bold text-[#18181B]">{kiosk.name.toUpperCase()}</td>
                  <td className="px-6 py-5">
                    <span className="flex items-center gap-2">
                       <div className={`w-1.5 h-1.5 rounded-full ${
                         kiosk.status === 'online' ? 'bg-emerald-500' : 
                         kiosk.status === 'locked' ? 'bg-red-500' :
                         kiosk.status === 'blocked' ? 'bg-red-500' : 'bg-[#A1A1AA]'
                       }`} />
                    <span className={`font-semibold ${
                         kiosk.status === 'online' ? 'text-emerald-600' : 
                         kiosk.status === 'locked' ? 'text-red-600' :
                         kiosk.status === 'queued' ? 'text-amber-600' :
                         kiosk.status === 'blocked' ? 'text-red-600' : 'text-[#71717A]'
                       }`}>
                         {kiosk.status.toUpperCase()}
                       </span>
                    </span>
                  </td>
                  <td className="px-6 py-5 text-[#71717A] font-medium">{kiosk.username || 'Guest'}</td>
                  <td className="px-6 py-5 font-mono text-[#A1A1AA]">{kiosk.ipAddress}</td>
                  <td className="px-6 py-5 font-mono font-bold text-[#18181B]">
                    {formatSessionValue(kiosk.remainingSeconds, kiosk.isSessionActive)}
                  </td>
                  <td className="px-6 py-5 text-right">
                    <div className="flex items-center justify-end gap-2">
                      {kiosk.isLocked ? (
                        <button 
                          onClick={async () => {
                            await setDeviceLock(kiosk.id, false);
                          }}
                          className="text-emerald-600 border border-emerald-600 px-3 py-1 rounded-sm text-[10px] font-bold hover:bg-emerald-600 hover:text-white transition-all cursor-pointer uppercase tracking-tighter"
                        >
                          Unlock
                        </button>
                      ) : (
                        <button 
                           onClick={async () => {
                             await setDeviceLock(kiosk.id, true);
                           }}
                           className="text-[#EF4444] border border-[#EF4444] px-3 py-1 rounded-sm text-[10px] font-bold hover:bg-[#EF4444] hover:text-white transition-all disabled:opacity-20 disabled:cursor-not-allowed cursor-pointer uppercase tracking-tighter"
                        >
                          Lock
                        </button>
                      )}
                      
                      <Menu as="div" className="relative">
                        <Menu.Button className="p-1.5 hover:bg-[#F4F4F5] rounded-sm transition-colors outline-none cursor-pointer">
                          <MoreVertical className="w-4 h-4 text-[#A1A1AA]" />
                        </Menu.Button>
                        <Transition
                          enter="transition duration-100 ease-out"
                          enterFrom="transform scale-95 opacity-0"
                          enterTo="transform scale-100 opacity-100"
                          leave="transition duration-75 ease-out"
                          leaveFrom="transform scale-100 opacity-100"
                          leaveTo="transform scale-95 opacity-0"
                        >
                          <Menu.Items className="absolute right-0 mt-2 w-40 bg-white border border-[#E4E4E7] rounded-sm shadow-sm z-10 py-1 outline-none">
                            <Menu.Item>
                              {({ active }) => (
                                <button className={`${active ? 'bg-[#F4F4F5]' : ''} w-full text-left px-3 py-2 text-[10px] font-bold uppercase text-[#18181B] tracking-wide`}>
                                  Diagnostics
                                </button>
                              )}
                            </Menu.Item>
                            <Menu.Item>
                              {({ active }) => (
                                <button className={`${active ? 'bg-[#F4F4F5]' : ''} w-full text-left px-3 py-2 text-[10px] font-bold uppercase text-[#18181B] tracking-wide`}>
                                  Reset Node
                                </button>
                              )}
                            </Menu.Item>
                          </Menu.Items>
                        </Transition>
                      </Menu>
                    </div>
                  </td>
                </motion.tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
