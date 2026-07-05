import nodemailer, { Transporter } from 'nodemailer';

// Real SMTP send when configured (see setup comment in .env), otherwise falls back to the same
// console-log-only dev mode this project already used for OTP-via-SMS — swapped transports
// (email is materially cheaper than per-message SMS pricing and needs no carrier integration),
// not the overall flow.
let transporter: Transporter | null | undefined; // undefined = not yet built, null = not configured

function getTransporter(): Transporter | null {
  if (transporter !== undefined) return transporter;

  const { SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD } = process.env;
  if (!SMTP_HOST || !SMTP_PORT || !SMTP_USER || !SMTP_PASSWORD) {
    transporter = null;
    return transporter;
  }

  transporter = nodemailer.createTransport({
    host: SMTP_HOST,
    port: parseInt(SMTP_PORT),
    // 465 is implicit TLS; 587 (and everything else) is STARTTLS — nodemailer needs this
    // spelled out rather than inferring it from the port.
    secure: parseInt(SMTP_PORT) === 465,
    auth: { user: SMTP_USER, pass: SMTP_PASSWORD },
  });
  return transporter;
}

export async function sendOTPEmail(email: string, code: string): Promise<void> {
  const client = getTransporter();

  if (!client) {
    console.log('\n========================================');
    console.log('📧 EMAIL VERIFICATION CODE (Local Dev Mode — SMTP not configured)');
    console.log(`Email: ${email}`);
    console.log(`Code: ${code}`);
    console.log('Valid for: 10 minutes');
    console.log('========================================\n');
    return;
  }

  const fromAddress = process.env.EMAIL_FROM_ADDRESS || process.env.SMTP_USER!;
  const fromName = process.env.EMAIL_FROM_NAME || 'Lumen';

  await client.sendMail({
    from: `"${fromName}" <${fromAddress}>`,
    to: email,
    subject: `${code} is your Lumen verification code`,
    text: `Your Lumen verification code is: ${code}\n\nValid for 10 minutes.`,
    html: `<p>Your Lumen verification code is: <strong>${code}</strong></p><p>Valid for 10 minutes.</p>`,
  });
}
