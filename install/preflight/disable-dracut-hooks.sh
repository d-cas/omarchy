# Temporarily disable dracut hooks to prevent multiple regenerations during package installation
# This speeds up installation significantly

echo "Temporarily disabling dracut hooks during installation..."

# Move the specific dracut pacman hooks out of the way if they exist
if [ -f /usr/share/libalpm/hooks/90-dracut-install.hook ]; then
  sudo mv /usr/share/libalpm/hooks/90-dracut-install.hook /usr/share/libalpm/hooks/90-dracut-install.hook.disabled
fi

if [ -f /usr/share/libalpm/hooks/60-dracut-remove.hook ]; then
  sudo mv /usr/share/libalpm/hooks/60-dracut-remove.hook /usr/share/libalpm/hooks/60-dracut-remove.hook.disabled
fi

echo "dracut hooks disabled"

