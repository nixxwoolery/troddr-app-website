import { NextResponse } from 'next/server';

const BOT_REGEX =
  /facebookexternalhit|twitterbot|slackbot|linkedinbot|whatsapp|telegrambot|discordbot|applebot|googlebot/i;

export function middleware(req) {
  const ua = req.headers.get('user-agent') || '';
  const url = req.nextUrl.clone();

  // Only intercept listing pages
  if (url.pathname.startsWith('/listings/') && BOT_REGEX.test(ua)) {
    const slug = url.pathname.split('/').pop();

    // Rewrite ONLY for bots to OG endpoint
    url.pathname = `/api/og/${slug}`;
    return NextResponse.rewrite(url);
  }

  // Everyone else gets the normal site
  return NextResponse.next();
}