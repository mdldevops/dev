import React, { useEffect } from 'react';
import { useStore } from '../store/useStore';

function formatRemainingTime(totalSeconds: number) {
  const safeSeconds = Math.max(0, totalSeconds || 0);
  const minutes = Math.floor(safeSeconds / 60);
  const seconds = safeSeconds % 60;
  return `${minutes.toString().padStart(2, '0')}:${seconds
    .toString()
    .padStart(2, '0')}`;
}

export default function Customers() {
  const { customers, loadCustomers, updateCustomerStatus } = useStore();

  useEffect(() => {
    loadCustomers();
    const intervalId = window.setInterval(() => {
      loadCustomers();
    }, 5000);

    return () => {
      window.clearInterval(intervalId);
    };
  }, [loadCustomers]);

  return (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-2 duration-500">
      <div>
        <h2 className="text-xl font-bold tracking-tight text-[#09090B]">
          Customer List
        </h2>
        <p className="mt-1 text-[10px] font-semibold uppercase tracking-widest text-[#71717A]">
          Account status and remaining saved time
        </p>
      </div>

      <div className="overflow-x-auto border border-[#E4E4E7] bg-white">
        <table className="w-full text-left">
          <thead className="border-b border-[#F4F4F5] bg-[#FAFAFA] text-[10px] uppercase text-[#71717A]">
            <tr>
              <th className="px-6 py-4 font-bold tracking-wider">Username</th>
              <th className="px-6 py-4 font-bold tracking-wider">Role</th>
              <th className="px-6 py-4 font-bold tracking-wider">Status</th>
              <th className="px-6 py-4 font-bold tracking-wider">
                Remaining Time
              </th>
              <th className="px-6 py-4 font-bold tracking-wider">Updated</th>
              <th className="px-6 py-4 text-right font-bold tracking-wider">
                Actions
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-[#F4F4F5] text-xs">
            {customers.map((customer) => {
              const isAdmin = customer.role.toLowerCase() === 'admin';
              const statusTone =
                customer.accountStatus === 'active'
                  ? 'text-emerald-600'
                  : customer.accountStatus === 'banned'
                    ? 'text-red-600'
                    : 'text-amber-600';

              return (
                <tr key={customer.username} className="hover:bg-[#FAFAFA]">
                  <td className="px-6 py-5 font-bold text-[#18181B]">
                    {customer.username}
                  </td>
                  <td className="px-6 py-5 font-medium text-[#71717A]">
                    {customer.role}
                  </td>
                  <td className={`px-6 py-5 font-semibold uppercase ${statusTone}`}>
                    {customer.accountStatus}
                  </td>
                  <td className="px-6 py-5 font-mono font-bold text-[#18181B]">
                    {formatRemainingTime(customer.savedSessionSeconds)}
                  </td>
                  <td className="px-6 py-5 text-[#71717A]">
                    {new Date(customer.updatedAt).toLocaleString()}
                  </td>
                  <td className="px-6 py-5">
                    <div className="flex justify-end gap-2">
                      <button
                        onClick={async () => {
                          await updateCustomerStatus(customer.username, 'active');
                        }}
                        disabled={isAdmin || customer.accountStatus === 'active'}
                        className="rounded-sm border border-emerald-600 px-3 py-1 text-[10px] font-bold uppercase tracking-tighter text-emerald-600 transition-all hover:bg-emerald-600 hover:text-white disabled:cursor-not-allowed disabled:opacity-30"
                      >
                        Activate
                      </button>
                      <button
                        onClick={async () => {
                          await updateCustomerStatus(
                            customer.username,
                            'deactivated',
                          );
                        }}
                        disabled={isAdmin || customer.accountStatus === 'deactivated'}
                        className="rounded-sm border border-amber-600 px-3 py-1 text-[10px] font-bold uppercase tracking-tighter text-amber-600 transition-all hover:bg-amber-600 hover:text-white disabled:cursor-not-allowed disabled:opacity-30"
                      >
                        Deactivate
                      </button>
                      <button
                        onClick={async () => {
                          await updateCustomerStatus(customer.username, 'banned');
                        }}
                        disabled={isAdmin || customer.accountStatus === 'banned'}
                        className="rounded-sm border border-red-600 px-3 py-1 text-[10px] font-bold uppercase tracking-tighter text-red-600 transition-all hover:bg-red-600 hover:text-white disabled:cursor-not-allowed disabled:opacity-30"
                      >
                        Ban
                      </button>
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
