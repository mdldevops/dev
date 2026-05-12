import React, { useEffect, useMemo, useState } from 'react';
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Cell,
} from 'recharts';
import { Download } from 'lucide-react';
import { useStore } from '../store/useStore';

type FilterType = '30days' | 'monthly' | 'previous' | 'custom';

const toDateKey = (value: string | undefined | null) => {
  return String(value || '').split(/[ T]/)[0] || '';
};

export default function Sales() {
  const { salesHistory, salesLogs, loadSales } = useStore();
  const [filter, setFilter] = useState<FilterType>('30days');

  useEffect(() => {
    loadSales();
    const intervalId = window.setInterval(() => {
      loadSales();
    }, 5000);

    return () => {
      window.clearInterval(intervalId);
    };
  }, [loadSales]);

  const filteredData = useMemo(() => {
    const now = new Date();
    const currentMonth = now.getMonth();
    const currentYear = now.getFullYear();

    switch (filter) {
      case '30days':
        return salesHistory.slice(-30);
      case 'monthly':
        return salesHistory.filter((item) => {
          const d = new Date(item.date);
          return d.getMonth() === currentMonth && d.getFullYear() === currentYear;
        });
      case 'previous': {
        const prevMonth = currentMonth === 0 ? 11 : currentMonth - 1;
        const prevYear = currentMonth === 0 ? currentYear - 1 : currentYear;
        return salesHistory.filter((item) => {
          const d = new Date(item.date);
          return d.getMonth() === prevMonth && d.getFullYear() === prevYear;
        });
      }
      default:
        return salesHistory;
    }
  }, [salesHistory, filter]);

  const filteredLogs = useMemo(() => {
    const filteredDates = new Set(filteredData.map((item) => item.date));
    return salesLogs.filter((item) => {
      const dateKey = toDateKey(item.createdAt);
      return filteredDates.has(dateKey);
    });
  }, [filteredData, salesLogs]);

  const totalSales = filteredData.reduce((sum, item) => sum + item.amount, 0);
  const avgSales = totalSales / (filteredData.length || 1);

  return (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-2 duration-500">
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h2 className="text-xl font-bold tracking-tight text-[#09090B]">Sales Analytics</h2>
          <p className="text-[10px] text-[#71717A] uppercase tracking-widest font-semibold mt-1">
            Revenue flow and transaction auditing
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button className="flex items-center gap-2 bg-white border border-[#E4E4E7] px-4 py-2 rounded-sm text-[10px] font-bold text-[#18181B] uppercase tracking-widest hover:bg-[#FAFAFA] transition-colors cursor-pointer">
            <Download className="w-3.5 h-3.5" />
            Export CSV
          </button>
        </div>
      </div>

      <div className="grid grid-cols-12 gap-6">
        <div className="col-span-12 bg-white border border-[#E4E4E7] p-4 flex items-center justify-between">
          <div className="flex gap-px bg-[#E4E4E7] border border-[#E4E4E7] shrink-0">
            {[
              { id: '30days', label: 'Last 30 Days' },
              { id: 'monthly', label: 'This Month' },
              { id: 'previous', label: 'Prev Month' },
              { id: 'custom', label: 'All Time' },
            ].map((t) => (
              <button
                key={t.id}
                onClick={() => setFilter(t.id as FilterType)}
                className={`px-4 py-2 text-[10px] font-bold uppercase tracking-widest transition-all cursor-pointer ${
                  filter === t.id
                    ? 'bg-[#18181B] text-white'
                    : 'bg-white text-[#71717A] hover:bg-[#FAFAFA]'
                }`}
              >
                {t.label}
              </button>
            ))}
          </div>

          <div className="flex items-center gap-4">
            <div className="text-right">
              <p className="text-[9px] font-bold text-[#A1A1AA] uppercase tracking-tighter">
                Total Period Sales
              </p>
              <p className="text-xl font-light text-[#18181B]">₱{totalSales.toLocaleString()}</p>
            </div>
            <div className="w-px h-8 bg-[#E4E4E7]" />
            <div className="text-right">
              <p className="text-[9px] font-bold text-[#A1A1AA] uppercase tracking-tighter">
                Daily Average
              </p>
              <p className="text-xl font-light text-[#18181B]">
                ₱{Math.round(avgSales).toLocaleString()}
              </p>
            </div>
          </div>
        </div>

        <div className="col-span-12 lg:col-span-8 bg-white border border-[#E4E4E7] p-8">
          <div className="flex items-center justify-between mb-8">
            <h3 className="text-xs font-bold uppercase tracking-[0.2em] text-[#18181B]">
              Revenue Distribution
            </h3>
            <div className="flex items-center gap-2">
              <div className="w-2 h-2 bg-[#18181B] rounded-full" />
              <span className="text-[10px] font-bold text-[#71717A] uppercase">
                Daily Collection
              </span>
            </div>
          </div>

          <div className="h-[300px] w-full">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={filteredData}>
                <CartesianGrid strokeDasharray="0" vertical={false} stroke="#F4F4F5" />
                <XAxis
                  dataKey="date"
                  axisLine={false}
                  tickLine={false}
                  tick={{ fontSize: 9, fill: '#A1A1AA', fontWeight: 600 }}
                  tickFormatter={(val) => val.split('-').slice(1).join('/')}
                  dy={10}
                />
                <YAxis
                  axisLine={false}
                  tickLine={false}
                  tick={{ fontSize: 9, fill: '#A1A1AA', fontWeight: 600 }}
                />
                <Tooltip
                  cursor={{ fill: '#F4F4F5' }}
                  contentStyle={{
                    borderRadius: '0px',
                    border: '1px solid #E4E4E7',
                    boxShadow: 'none',
                    padding: '8px',
                    fontSize: '10px',
                    fontWeight: 'bold',
                  }}
                />
                <Bar dataKey="amount" radius={[2, 2, 0, 0]}>
                  {filteredData.map((entry, index) => (
                    <Cell
                      key={`cell-${index}`}
                      fill={entry.amount > avgSales ? '#18181B' : '#E4E4E7'}
                    />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </div>
        </div>

        <div className="col-span-12 lg:col-span-4 bg-white border border-[#E4E4E7] flex flex-col overflow-hidden">
          <div className="p-4 border-b border-[#F4F4F5] bg-white">
            <h3 className="text-[10px] font-bold uppercase tracking-widest text-[#18181B]">
              Live Transaction Log
            </h3>
          </div>
          <div className="overflow-auto flex-1 max-h-[380px]">
            <table className="w-full text-left">
              <thead className="bg-[#FAFAFA] text-[9px] uppercase text-[#71717A] border-b border-[#F4F4F5] sticky top-0">
                <tr>
                  <th className="px-6 py-3 font-bold">Date</th>
                  <th className="px-6 py-3 font-bold text-right">Amount</th>
                </tr>
              </thead>
              <tbody className="text-[11px] divide-y divide-[#F4F4F5]">
                {filteredLogs.map((item) => (
                  <tr key={item.id} className="hover:bg-[#FAFAFA] transition-colors">
                    <td className="px-6 py-3 font-mono font-bold text-[#A1A1AA]">
                      {new Date(item.createdAt).toLocaleString()}
                    </td>
                    <td className="px-6 py-3 text-right font-bold text-[#18181B]">
                      ₱{Number(item.coinValue || 0).toFixed(2)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
  );
}
