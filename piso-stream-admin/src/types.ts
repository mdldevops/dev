export interface Kiosk {
  id: string;
  name: string;
  status: 'online' | 'offline' | 'blocked' | 'queued' | 'locked';
  lastSeen: string;
  ipAddress: string;
  username: string;
  isLocked?: boolean;
  queuePosition?: number;
  isSessionActive?: boolean;
  totalInserted?: number;
  creditedMinutes?: number;
  remainingSeconds?: number;
  isSelected?: boolean;
}

export interface CustomerAccount {
  username: string;
  role: string;
  accountStatus: 'active' | 'deactivated' | 'banned';
  savedSessionSeconds: number;
  createdAt: string;
  updatedAt: string;
}

export interface Session {
  id: string;
  kioskId: string;
  userName: string;
  startTime: string;
  timeLeft: number; // in seconds
  totalSpent: number;
}

export interface SalesData {
  date: string;
  amount: number;
}

export interface CoinLog {
  id: number;
  deviceId: string;
  coinValue: number;
  creditedMinutes: number;
  source: string;
  createdAt: string;
}

export interface AppSettings {
  coinToTimeRatio: number; // base ratio
  ratios: {
    p1: number;
    p5: number;
    p10: number;
    p20: number;
  };
  broadcastMessage: string;
}
