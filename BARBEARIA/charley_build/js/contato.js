import { $, mountChrome, registerSW, getSettings, waLink, maskPhone, onlyDigits, toast } from './common.js';
registerSW();
await mountChrome('contato.html');
const s = await getSettings();
$('#addr').textContent = s.shop_address;
$('#map').src = 'https://www.google.com/maps?q=' + encodeURIComponent(s.shop_address) + '&output=embed';
$('#route').href = 'https://www.google.com/maps/dir/?api=1&destination=' + encodeURIComponent(s.shop_address);
$('#wa').href = waLink(s.shop_whatsapp);
$('#ig').href = s.shop_instagram;
$('#phone').addEventListener('input', (e) => { e.target.value = maskPhone(e.target.value); });
// O formulário NÃO guarda nada no banco: só abre o WhatsApp com a mensagem pronta.
$('#form').addEventListener('submit', (e) => {
  e.preventDefault();
  const name = $('#name').value.trim(), msg = $('#msg').value.trim(), ph = onlyDigits($('#phone').value);
  if (name.length < 2) return toast('Informe seu nome.', 'error');
  if (msg.length < 3) return toast('Escreva sua mensagem.', 'error');
  const text = `Olá! Meu nome é ${name}.${ph.length >= 10 ? ' Meu WhatsApp: ' + maskPhone(ph) + '.' : ''}\n\n${msg}`;
  window.open(waLink(s.shop_whatsapp, text), '_blank', 'noopener');
});
