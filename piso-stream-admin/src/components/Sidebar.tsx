import React from 'react';
import { NavLink } from 'react-router-dom';
import { LayoutDashboard, Monitor, Users, Settings, LogOut, TrendingUp, UserRound } from 'lucide-react';
import { useStore } from '../store/useStore';
import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';

function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export default function Sidebar() {
  const logout = useStore((state) => state.logout);

  const links = [
    { to: '/', icon: LayoutDashboard, label: 'Dashboard' },
    { to: '/devices', icon: Monitor, label: 'Devices' },
    { to: '/sessions', icon: Users, label: 'Sessions' },
    { to: '/customers', icon: UserRound, label: 'Customers' },
    { to: '/sales', icon: TrendingUp, label: 'Sales' },
    { to: '/settings', icon: Settings, label: 'Settings' },
  ];

  return (
    <aside className="w-60 bg-white border-r border-[#E4E4E7] flex flex-col h-screen fixed left-0 top-0 z-30 shrink-0">
      <div className="p-6">
        <div className="mb-8">
          <h1 className="text-xl font-bold tracking-tight text-[#09090B]">PISO STREAM</h1>
          <p className="text-[10px] text-[#71717A] uppercase tracking-widest font-semibold mt-1">Admin Dashboard</p>
        </div>

        <nav className="space-y-1">
          {links.map((link) => (
            <NavLink
              key={link.to}
              to={link.to}
              className={({ isActive }) =>
                cn(
                  "flex items-center gap-3 px-3 py-2 transition-all duration-150 text-sm",
                  isActive 
                    ? "bg-[#F4F4F5] text-[#18181B] font-medium rounded-md" 
                    : "text-[#71717A] hover:bg-[#FAFAFA] rounded-md"
                )
              }
            >
              <link.icon className="w-4 h-4" />
              <span>{link.label}</span>
            </NavLink>
          ))}
        </nav>
      </div>

      <div className="mt-auto p-6 border-t border-[#F4F4F5]">
        <div className="flex items-center gap-3 mb-4 px-2">
          <div className="w-8 h-8 rounded-full bg-[#E4E4E7] flex items-center justify-center text-[10px] font-bold">AD</div>
          <div>
            <p className="text-xs font-semibold">Admin Root</p>
            <p className="text-[10px] text-[#71717A]">System Online</p>
          </div>
        </div>
        <button
          onClick={logout}
          className="flex items-center gap-3 px-3 py-2 w-full text-left text-[#71717A] hover:text-[#EF4444] transition-colors rounded-md text-sm"
        >
          <LogOut className="w-4 h-4" />
          <span>Sign Out</span>
        </button>
      </div>
    </aside>
  );
}
