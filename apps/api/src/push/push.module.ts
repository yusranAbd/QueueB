import {
  Body,
  Controller,
  Delete,
  Module,
  Put,
  UseGuards,
} from '@nestjs/common';
import { Throttle, ThrottlerGuard } from '@nestjs/throttler';
import { IsIn, IsString, Matches, MaxLength } from 'class-validator';
import { AuthModule } from '../auth/auth.module';
import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import { JwtAuthGuard } from '../auth/guards/jwt-auth.guard';
import { RolesGuard } from '../auth/guards/roles.guard';
import type { AuthenticatedUser } from '../auth/auth.types';
import { PeranPengguna } from '../generated/prisma/client';
import { PrismaModule } from '../prisma/prisma.module';
import { FcmClient } from './fcm.client';
import { PerangkatPushService } from './perangkat-push.service';
import { PushDispatcherService } from './push-dispatcher.service';

const POLA_TOKEN = /^[\x21-\x7E]{1,4096}$/;

export class HapusPerangkatPushDto {
  @IsString()
  @MaxLength(4096)
  @Matches(POLA_TOKEN, { message: 'Token perangkat tidak valid' })
  token!: string;
}

export class DaftarPerangkatPushDto extends HapusPerangkatPushDto {
  @IsIn(['ANDROID'])
  platform!: 'ANDROID';
}

@Controller('perangkat-push')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles(PeranPengguna.USER)
export class PerangkatPushController {
  constructor(private readonly service: PerangkatPushService) {}

  @Put()
  @UseGuards(ThrottlerGuard)
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  daftar(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: DaftarPerangkatPushDto,
  ) {
    return this.service.daftar(user, dto.token, dto.platform);
  }

  @Delete()
  hapus(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: HapusPerangkatPushDto,
  ) {
    return this.service.hapus(user, dto.token);
  }
}

@Module({
  imports: [AuthModule, PrismaModule],
  controllers: [PerangkatPushController],
  providers: [FcmClient, PerangkatPushService, PushDispatcherService],
})
export class PushModule {}
