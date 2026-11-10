import type { INestApplication } from '@nestjs/common';
import { configureApp } from './configure-app';

// Modul Nest berformat ESM tidak dimuat Jest unit; yang diuji hanya sinkronisasi env.
jest.mock('@nestjs/common', () => ({ ValidationPipe: class {} }));
jest.mock('@nestjs/config', () => ({ ConfigService: class {} }));

describe('configureApp: sinkronisasi CORS_ALLOWED_ORIGINS', () => {
  const lama = process.env.CORS_ALLOWED_ORIGINS;

  afterEach(() => {
    if (lama === undefined) delete process.env.CORS_ALLOWED_ORIGINS;
    else process.env.CORS_ALLOWED_ORIGINS = lama;
  });

  function aplikasi(origins: string[] | undefined) {
    const enableCors = jest.fn();
    const app = {
      get: () => ({ get: () => origins }),
      enableCors,
      setGlobalPrefix: jest.fn(),
      useGlobalPipes: jest.fn(),
    } as unknown as INestApplication;
    return { app, enableCors };
  }

  it('menyalin daftar origin tervalidasi ke process.env untuk Socket.IO', () => {
    delete process.env.CORS_ALLOWED_ORIGINS;
    const origins = ['http://localhost:3000', 'https://preview.ngrok-free.dev'];
    const { app, enableCors } = aplikasi(origins);
    configureApp(app);
    expect(process.env.CORS_ALLOWED_ORIGINS).toBe(origins.join(','));
    expect(enableCors).toHaveBeenCalledWith({
      origin: origins,
      credentials: true,
    });
  });

  it('tidak mengubah process.env jika daftar kosong', () => {
    process.env.CORS_ALLOWED_ORIGINS = 'http://localhost:5173';
    configureApp(aplikasi([]).app);
    expect(process.env.CORS_ALLOWED_ORIGINS).toBe('http://localhost:5173');
  });
});
