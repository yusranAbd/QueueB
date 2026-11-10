import { INestApplication, ValidationPipe } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

export function configureApp(app: INestApplication): void {
  const config = app.get(ConfigService);
  const allowedOrigins = config.get<string[]>('CORS_ALLOWED_ORIGINS') ?? [];

  // ConfigModule tidak menyalin array ke process.env, sedangkan pemeriksa Origin
  // Socket.IO dan cookie display membaca process.env langsung. Samakan dengan
  // daftar tervalidasi agar nilai dari .env berlaku di semua jalur.
  if (allowedOrigins.length > 0) {
    process.env.CORS_ALLOWED_ORIGINS = allowedOrigins.join(',');
  }

  // Origin HTTP khusus browser. Autentikasi dan otorisasi tetap di endpoint.
  // Socket.IO memerlukan pemeriksaan origin terpisah pada kedua gateway.
  app.enableCors({ origin: allowedOrigins, credentials: true });

  app.setGlobalPrefix('api/v1');

  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
    }),
  );
}
