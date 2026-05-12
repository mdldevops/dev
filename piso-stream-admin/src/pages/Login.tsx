import React, { useState } from 'react';
import { useStore } from '../store/useStore';
import { motion, AnimatePresence } from 'motion/react';
import { useNavigate } from 'react-router-dom';

export default function Login() {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const login = useStore((state) => state.login);
  const navigate = useNavigate();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsLoading(true);
    setError(false);
    
    await new Promise(r => setTimeout(r, 600));
    
    const success = await login(username, password);
    if (success) {
      navigate('/', { replace: true });
    } else {
      setError(true);
      setIsLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-[#F4F4F5] flex items-center justify-center p-4">
      <motion.div 
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        className="max-w-md w-full bg-white border border-[#E4E4E7] p-12"
      >
        <div className="mb-12">
          <h1 className="text-2xl font-bold text-[#18181B] tracking-tight">PISO STREAM</h1>
          <p className="text-[10px] text-[#A1A1AA] uppercase tracking-[0.3em] font-bold mt-1">Terminal Authentication</p>
        </div>

        <form onSubmit={handleSubmit} className="space-y-8">
          <div>
            <label className="block text-[10px] font-bold text-[#71717A] uppercase tracking-[0.2em] mb-3">Admin Username</label>
            <div className="relative mb-4">
              <input
                type="text"
                required
                className="w-full px-4 py-4 bg-[#F4F4F5] border-none text-sm focus:ring-1 focus:ring-[#18181B] outline-none transition-all placeholder:text-[#A1A1AA] font-mono"
                placeholder="admin"
                value={username}
                onChange={(e) => setUsername(e.target.value)}
              />
            </div>
            <label className="block text-[10px] font-bold text-[#71717A] uppercase tracking-[0.2em] mb-3">Admin Password</label>
            <div className="relative">
              <input
                type="password"
                required
                className="w-full px-4 py-4 bg-[#F4F4F5] border-none text-sm focus:ring-1 focus:ring-[#18181B] outline-none transition-all placeholder:text-[#A1A1AA] font-mono tracking-widest"
                placeholder="••••••••"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
              />
            </div>
            <AnimatePresence>
              {error && (
                <motion.p 
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  className="text-red-600 text-[10px] mt-4 font-bold uppercase tracking-widest"
                >
                  Access denied. Check server connection or admin credentials.
                </motion.p>
              )}
            </AnimatePresence>
          </div>

          <button
            type="submit"
            disabled={isLoading}
            className="w-full bg-[#18181B] text-white py-4 text-xs font-bold uppercase tracking-[0.3em] hover:bg-black transition-all active:scale-[0.98] disabled:opacity-50 cursor-pointer"
          >
            {isLoading ? 'Authenticating...' : 'Enter System'}
          </button>
        </form>

        <div className="mt-12 pt-8 border-t border-[#F4F4F5]">
            <div className="flex items-center gap-2">
              <div className="w-1 h-1 bg-emerald-500 rounded-full"></div>
              <p className="text-[9px] text-[#A1A1AA] uppercase tracking-widest font-bold">Standard encryption active</p>
            </div>
        </div>
      </motion.div>
    </div>
  );
}
