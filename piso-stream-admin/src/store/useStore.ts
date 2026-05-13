import { create } from 'zustand';
import {
  Kiosk,
  Session,
  AppSettings,
  SalesData,
  CoinLog,
  CustomerAccount,
} from '../types';

interface AppState {
  isAuthenticated: boolean;
  user: { name: string; role: string } | null;
  kiosks: Kiosk[];
  customers: CustomerAccount[];
  sessions: Session[];
  settings: AppSettings;
  salesHistory: SalesData[];
  salesLogs: CoinLog[];
  selectedDeviceIds: string[];
  
  // Actions
  login: (username: string, password: string) => Promise<boolean>;
  logout: () => void;
  loadDevices: () => Promise<void>;
  loadCustomers: () => Promise<void>;
  loadSessions: () => Promise<void>;
  loadSales: () => Promise<void>;
  loadSettings: () => Promise<void>;
  setDeviceLock: (id: string, isLocked: boolean) => Promise<boolean>;
  updateCustomerStatus: (
    username: string,
    status: CustomerAccount['accountStatus'],
  ) => Promise<boolean>;
  toggleSelectedDevice: (id: string) => void;
  clearSelectedDevices: () => void;
  updateSettings: (settings: Partial<AppSettings>) => Promise<boolean>;
  broadcast: (message: string, deviceIds?: string[]) => Promise<boolean>;
}

const API_BASE_URL =
  import.meta.env.VITE_API_BASE_URL?.trim() || 'www.server.pisostream.online';

const toDateKey = (value: string | undefined | null) => {
  return String(value || '').split(/[ T]/)[0] || '';
};

export const useStore = create<AppState>((set, get) => ({
  isAuthenticated: false,
  user: null,
  kiosks: [],
  customers: [],
  sessions: [],
  settings: {
    coinToTimeRatio: 6,
    ratios: {
      p1: 6,
      p5: 30,
      p10: 60,
      p20: 120,
    },
    broadcastMessage: '',
  },
  salesHistory: [],
  salesLogs: [],
  selectedDeviceIds: [],

  login: async (username: string, password: string) => {
    try {
      const response = await fetch(`${API_BASE_URL}/auth/login`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          username,
          password,
        }),
      });

      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        return false;
      }

      if ((body.role ?? '').toLowerCase() !== 'admin') {
        return false;
      }

      const normalizedUsername = String(body.username ?? username).trim();
      set({
      isAuthenticated: true,
      user: {
        name: normalizedUsername || 'Admin',
        role: 'admin',
      },
      });
      await get().loadSettings();
      await get().loadDevices();
      await get().loadCustomers();
      await get().loadSessions();
      await get().loadSales();
      return true;
    } catch (error) {
      console.error('Admin login failed', error);
      return false;
    }
  },

  logout: () =>
    set({
      isAuthenticated: false,
      user: null,
      kiosks: [],
      customers: [],
      sessions: [],
      salesHistory: [],
      salesLogs: [],
      selectedDeviceIds: [],
      settings: {
        coinToTimeRatio: 6,
        ratios: {
          p1: 6,
          p5: 30,
          p10: 60,
          p20: 120,
        },
        broadcastMessage: '',
      },
    }),

  loadDevices: async () => {
    try {
      const response = await fetch(`${API_BASE_URL}/devices`);
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        return;
      }

      const items = Array.isArray(body.items) ? (body.items as Kiosk[]) : [];
      set((state) => ({
        kiosks: items.map((item) => ({
          ...item,
          isSelected: state.selectedDeviceIds.includes(item.id),
        })),
      }));
    } catch (error) {
      console.error('Load devices failed', error);
    }
  },

  loadCustomers: async () => {
    try {
      const response = await fetch(`${API_BASE_URL}/customers`);
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        return;
      }

      const items = Array.isArray(body.items)
        ? (body.items as CustomerAccount[])
        : [];
      set({ customers: items });
    } catch (error) {
      console.error('Load customers failed', error);
    }
  },

  loadSessions: async () => {
    try {
      const response = await fetch(`${API_BASE_URL}/sessions`);
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        return;
      }

      const items = Array.isArray(body.items) ? (body.items as Session[]) : [];
      set({ sessions: items });
    } catch (error) {
      console.error('Load sessions failed', error);
    }
  },

  loadSales: async () => {
    try {
      const response = await fetch(`${API_BASE_URL}/sales/coin-logs?limit=1000`);
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        return;
      }

      const items = Array.isArray(body.items) ? (body.items as CoinLog[]) : [];
      const salesByDate = new Map<string, number>();

      items.forEach((item) => {
        const dateKey = toDateKey(item.createdAt);
        if (!dateKey) {
          return;
        }

        salesByDate.set(
          dateKey,
          Number(salesByDate.get(dateKey) || 0) + Number(item.coinValue || 0),
        );
      });

      const salesHistory = Array.from(salesByDate.entries())
        .map(([date, amount]) => ({ date, amount }))
        .sort((left, right) => left.date.localeCompare(right.date));

      set({
        salesLogs: items,
        salesHistory,
      });
    } catch (error) {
      console.error('Load sales failed', error);
    }
  },

  loadSettings: async () => {
    try {
      const response = await fetch(`${API_BASE_URL}/settings/coin-config`);
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        return;
      }

      const ratios = body?.ratios ?? {};
      const normalizedRatios = {
        p1: Number(ratios.p1) || 6,
        p5: Number(ratios.p5) || 30,
        p10: Number(ratios.p10) || 60,
        p20: Number(ratios.p20) || 120,
      };

      set((state) => ({
        settings: {
          ...state.settings,
          coinToTimeRatio: normalizedRatios.p1,
          ratios: normalizedRatios,
        },
      }));
    } catch (error) {
      console.error('Load settings failed', error);
    }
  },

  setDeviceLock: async (id, isLocked) => {
    try {
      const response = await fetch(`${API_BASE_URL}/devices/lock`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          deviceId: id,
          isLocked,
        }),
      });

      if (!response.ok) {
        return false;
      }

      await get().loadDevices();
      return true;
    } catch (error) {
      console.error('Set device lock failed', error);
      return false;
    }
  },

  updateCustomerStatus: async (username, status) => {
    try {
      const response = await fetch(`${API_BASE_URL}/customers/status`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          username,
          status,
        }),
      });

      if (!response.ok) {
        return false;
      }

      await get().loadCustomers();
      return true;
    } catch (error) {
      console.error('Update customer status failed', error);
      return false;
    }
  },

  toggleSelectedDevice: (id) => set((state) => {
    const isSelected = state.selectedDeviceIds.includes(id);
    const selectedDeviceIds = isSelected
      ? state.selectedDeviceIds.filter((deviceId) => deviceId !== id)
      : [...state.selectedDeviceIds, id];

    return {
      selectedDeviceIds,
      kiosks: state.kiosks.map((kiosk) =>
        kiosk.id === id ? { ...kiosk, isSelected: !isSelected } : kiosk,
      ),
    };
  }),

  clearSelectedDevices: () => set((state) => ({
    selectedDeviceIds: [],
    kiosks: state.kiosks.map((kiosk) => ({ ...kiosk, isSelected: false })),
  })),

  updateSettings: async (newSettings) => {
    const nextRatios = newSettings.ratios;

    if (nextRatios) {
      try {
        const response = await fetch(`${API_BASE_URL}/settings/coin-config`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            ratios: nextRatios,
          }),
        });

        const body = await response.json().catch(() => ({}));
        if (response.ok) {
          const savedRatios = body?.ratios ?? nextRatios;
          set((state) => ({
            settings: {
              ...state.settings,
              ...newSettings,
              coinToTimeRatio: Number(savedRatios.p1) || state.settings.coinToTimeRatio,
              ratios: {
                p1: Number(savedRatios.p1) || 6,
                p5: Number(savedRatios.p5) || 30,
                p10: Number(savedRatios.p10) || 60,
                p20: Number(savedRatios.p20) || 120,
              },
            },
          }));
          return true;
        }
      } catch (error) {
        console.error('Update settings failed', error);
      }

      return false;
    }

    set((state) => ({
      settings: { ...state.settings, ...newSettings }
    }));

    return true;
  },

  broadcast: async (message, deviceIds = []) => {
    const normalizedMessage = String(message || '').trim();
    if (!normalizedMessage) {
      return false;
    }

    const normalizedDeviceIds = Array.isArray(deviceIds)
      ? deviceIds
          .map((deviceId) => String(deviceId || '').trim())
          .filter((deviceId) => deviceId.length > 0)
      : [];

    try {
      const response = await fetch(`${API_BASE_URL}/broadcast`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          message: normalizedMessage,
          deviceIds: normalizedDeviceIds,
        }),
      });

      if (!response.ok) {
        return false;
      }

      console.log('Broadcasting global message:', normalizedMessage);
      set((state) => ({
        settings: { ...state.settings, broadcastMessage: normalizedMessage },
      }));
      setTimeout(
        () =>
          set((state) => ({
            settings: { ...state.settings, broadcastMessage: '' },
          })),
        5000,
      );
      return true;
    } catch (error) {
      console.error('Broadcast failed', error);
      return false;
    }
  },
}));
