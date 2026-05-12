import React, { useEffect } from 'react';
import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from 'recharts';
import { useStore } from '../store/useStore';

const StatCard = ({
  title,
  value,
  sub,
  colorClass = 'text-[#71717A]',
}: any) => (
  <div className="col-span-4 bg-white border border-[#E4E4E7] p-6 flex flex-col justify-between min-h-[140px]">
    <p className="text-xs font-medium text-[#71717A] uppercase tracking-wider">{title}</p>
    <div>
      <p className="text-3xl font-light tracking-tighter text-[#18181B]">{value}</p>
      {sub && (
        <p className={`text-[10px] mt-1 font-bold uppercase tracking-tighter ${colorClass}`}>
          {sub}
        </p>
      )}
    </div>
  </div>
);

export default function Dashboard() {
  const { kiosks, sessions, salesHistory, loadDevices, loadSessions, loadSales } = useStore();

  useEffect(() => {
    const loadAll = () => {
      loadDevices();
      loadSessions();
      loadSales();
    };

    loadAll();
    const intervalId = window.setInterval(loadAll, 5000);

    return () => {
      window.clearInterval(intervalId);
    };
  }, [loadDevices, loadSales, loadSessions]);

  const activeKiosks = kiosks.filter((k) => k.status === 'online').length;
  const todayKey = new Date().toISOString().split('T')[0];
  const totalDailySales =
    salesHistory.find((item) => item.date === todayKey)?.amount ?? 0;
  const utilizationRate =
    kiosks.length > 0 ? Math.round((activeKiosks / kiosks.length) * 100) : 0;

  return (
    <div className="space-y-8 animate-in fade-in duration-500">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-sm font-bold uppercase tracking-[0.2em] text-[#A1A1AA]">
            Real-time Network State
          </h2>
        </div>
        <div className="px-3 py-1 bg-white border border-[#E4E4E7] rounded-sm text-[10px] font-bold text-[#71717A]">
          UPDATED: {new Date().toLocaleTimeString()}
        </div>
      </div>

      <div className="grid grid-cols-12 gap-6">
        <StatCard
          title="Total Daily Sales"
          value={`₱${totalDailySales.toLocaleString()}`}
          sub="+12% from yesterday"
          colorClass="text-emerald-600"
        />
        <StatCard
          title="Active Kiosks"
          value={`${activeKiosks} / ${kiosks.length}`}
          sub={`${utilizationRate}% Utilization rate`}
          colorClass="text-[#71717A]"
        />
        <StatCard
          title="Live Sessions"
          value={sessions.length}
          sub="Peak activity now"
          colorClass="text-sky-600"
        />

        <div className="col-span-8 bg-white border border-[#E4E4E7] p-8 flex flex-col">
          <div className="flex items-center justify-between mb-8">
            <h3 className="text-xs font-bold uppercase tracking-[0.2em] text-[#18181B]">
              Weekly Revenue Flow
            </h3>
            <div className="flex gap-2">
              <div className="w-2 h-2 bg-brand-500 rounded-full" />
              <span className="text-[10px] font-bold text-[#71717A] uppercase">
                Pesos (PHP)
              </span>
            </div>
          </div>

          <div className="h-[280px] w-full">
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={salesHistory}>
                <defs>
                  <linearGradient id="colorAmount" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%" stopColor="#18181B" stopOpacity={0.05} />
                    <stop offset="95%" stopColor="#18181B" stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="0" vertical={false} stroke="#F4F4F5" />
                <XAxis
                  dataKey="date"
                  axisLine={false}
                  tickLine={false}
                  tick={{ fontSize: 10, fill: '#A1A1AA', fontWeight: 600 }}
                  tickFormatter={(val) => val.split('-').slice(1).join('/')}
                  dy={10}
                />
                <YAxis
                  axisLine={false}
                  tickLine={false}
                  tick={{ fontSize: 10, fill: '#A1A1AA', fontWeight: 600 }}
                />
                <Tooltip
                  contentStyle={{
                    borderRadius: '0px',
                    border: '1px solid #E4E4E7',
                    boxShadow: 'none',
                    padding: '8px',
                    fontSize: '10px',
                    fontWeight: 'bold',
                  }}
                  cursor={{ stroke: '#18181B', strokeWidth: 1 }}
                />
                <Area
                  type="stepAfter"
                  dataKey="amount"
                  stroke="#18181B"
                  strokeWidth={1.5}
                  fillOpacity={1}
                  fill="url(#colorAmount)"
                />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        </div>

        <div className="col-span-4 flex flex-col gap-6">
          <div className="bg-[#18181B] p-8 text-white flex-1 relative overflow-hidden flex flex-col justify-between border border-[#18181B]">
            <div className="absolute -right-6 -bottom-6 w-32 h-32 border border-white/5 rounded-full pointer-events-none" />
            <div className="relative z-10">
              <h3 className="text-xs font-bold uppercase tracking-widest mb-2 opacity-50">
                Pulse Insight
              </h3>
              <p className="text-2xl font-light leading-tight">
                Revenue is up <span className="text-emerald-400 font-medium">14.2%</span> during
                peak evening hours (6PM - 10PM).
              </p>
            </div>
            <button className="relative z-10 mt-6 text-[10px] font-bold uppercase border-b border-white/20 pb-1 w-fit hover:border-white transition-colors cursor-pointer">
              Generate Full Report
            </button>
          </div>

          <div className="bg-white border border-[#E4E4E7] p-6 text-center">
            <p className="text-[10px] font-bold text-[#71717A] uppercase tracking-widest mb-1">
              System Health
            </p>
            <p className="text-xl font-light">99.9% Uptime</p>
          </div>
        </div>
      </div>
    </div>
  );
}
