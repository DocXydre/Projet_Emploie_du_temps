package fr.thomasmathis.planif.commun;

import java.time.Clock;
import java.time.ZoneId;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Horloge injectable. Aucune classe metier n'appelle {@code Instant.now()}
 * directement : le moteur de planification doit rester testable sur des
 * scenarios de semaine type a date figee.
 */
@Configuration
public class ConfigurationHorloge {

    /** Fuseau d'affichage de l'utilisateur. Le stockage reste en UTC. */
    public static final ZoneId FUSEAU_UTILISATEUR = ZoneId.of("Europe/Paris");

    @Bean
    public Clock horloge() {
        return Clock.systemUTC();
    }
}
