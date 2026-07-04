// LOCAL DEVELOPMENT MODE
// SMS is disabled - OTP codes are printed to console instead of being sent via Twilio

export async function sendOTP(phone: string, code: string): Promise<void> {
  console.log('\n========================================');
  console.log('📱 SMS VERIFICATION CODE (Local Dev Mode)');
  console.log(`Phone: ${phone}`);
  console.log(`Code: ${code}`);
  console.log('Valid for: 10 minutes');
  console.log('========================================\n');
  
  // In local dev mode, we just log the code instead of sending SMS
  // When ready to deploy, replace this with actual Twilio integration:
  /*
  import twilio from 'twilio';
  const client = twilio(
    process.env.TWILIO_ACCOUNT_SID,
    process.env.TWILIO_AUTH_TOKEN
  );
  await client.messages.create({
    body: `Your Lumen verification code is: ${code}. Valid for 10 minutes.`,
    from: process.env.TWILIO_PHONE_NUMBER,
    to: phone,
  });
  */
}
