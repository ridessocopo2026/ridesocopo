-- ============================================================
-- RIDESOCOPÓ - Reparación: Perfiles con OAuth (Google)
-- Ejecuta TODO este script en Supabase SQL Editor
-- ============================================================

-- 1. RECREAR FUNCIÓN handle_new_user con soporte OAuth
DROP FUNCTION IF EXISTS public.handle_new_user() CASCADE;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_full_name TEXT;
  v_avatar_url TEXT;
BEGIN
  v_full_name := COALESCE(
    NULLIF(NEW.raw_user_meta_data->>'full_name', ''),
    NULLIF(NEW.raw_user_meta_data->>'name', ''),
    NULLIF(NEW.raw_user_meta_data->>'preferred_username', ''),
    NULLIF(NEW.email, ''),
    'Usuario'
  );

  v_avatar_url := COALESCE(
    NULLIF(NEW.raw_user_meta_data->>'avatar_url', ''),
    NULLIF(NEW.raw_user_meta_data->>'picture', ''),
    NULL
  );

  INSERT INTO public.profiles (id, full_name, email, avatar_url)
  VALUES (NEW.id, v_full_name, NEW.email, v_avatar_url)
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;

EXCEPTION
  WHEN unique_violation THEN
    RETURN NEW;
  WHEN OTHERS THEN
    RAISE LOG 'handle_new_user error (user %): %', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$;

-- 2. RECREAR TRIGGER
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- 3. RECREAR TRIGGER DE BILLETERA
CREATE OR REPLACE FUNCTION public.handle_new_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.wallets (user_id)
  VALUES (NEW.id)
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_profile_created ON public.profiles;

CREATE TRIGGER on_profile_created
  AFTER INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_profile();

-- 4. PERMISOS
GRANT EXECUTE ON FUNCTION public.handle_new_user TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.handle_new_profile TO anon, authenticated, service_role;

-- 5. VERIFICACIÓN
SELECT 'Reparación perfiles OAuth completada' AS estado;