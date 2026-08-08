package fr.thomasmathis.planif.securite;

import java.io.IOException;
import java.time.Clock;
import java.time.OffsetDateTime;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;

import com.fasterxml.jackson.databind.ObjectMapper;

import fr.thomasmathis.planif.api.ErreurApi;
import fr.thomasmathis.planif.commun.FiltreCorrelation;
import jakarta.servlet.http.HttpServletResponse;

/**
 * Securite de l'API.
 *
 * <p>API sans session : chaque requete porte son jeton, aucun cookie, donc
 * aucune protection CSRF a mettre en place. Les erreurs d'authentification
 * sortent dans le meme format normalise que le reste de l'API.</p>
 */
@Configuration
@EnableWebSecurity
@EnableMethodSecurity
public class ConfigurationSecurite {

    /** Chemins accessibles sans jeton. Volontairement courts et explicites. */
    private static final String[] PUBLICS = {
            "/sante",
            "/api/v1/sante",
            "/api/v1/auth/connexion",
            "/api/v1/auth/rafraichir",
            "/openapi.json",
            "/openapi.json/**",
            "/documentation",
            "/documentation/**",
            "/swagger-ui/**"
    };

    @Bean
    public PasswordEncoder encodeurMotDePasse() {
        // BCrypt : cout 12, un cran au dessus du defaut, sans impact perceptible
        // sur deux connexions par jour.
        return new BCryptPasswordEncoder(12);
    }

    @Bean
    public SecurityFilterChain chaineFiltres(HttpSecurity http,
                                             FiltreJwt filtreJwt,
                                             ObjectMapper mapper,
                                             Clock horloge) throws Exception {
        http
                .csrf(csrf -> csrf.disable())
                .cors(cors -> cors.disable())
                .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(requetes -> requetes
                        .requestMatchers(PUBLICS).permitAll()
                        .anyRequest().authenticated())
                .exceptionHandling(gestion -> gestion
                        .authenticationEntryPoint((req, rep, ex) -> ecrireErreur(
                                mapper, horloge, rep, HttpStatus.UNAUTHORIZED,
                                "NON_AUTHENTIFIE", "Authentification requise"))
                        .accessDeniedHandler((req, rep, ex) -> ecrireErreur(
                                mapper, horloge, rep, HttpStatus.FORBIDDEN,
                                "ACTION_NON_AUTORISEE", "Droits insuffisants")))
                .addFilterBefore(filtreJwt, UsernamePasswordAuthenticationFilter.class);

        return http.build();
    }

    private void ecrireErreur(ObjectMapper mapper, Clock horloge, HttpServletResponse reponse,
                              HttpStatus statut, String code, String message) throws IOException {
        reponse.setStatus(statut.value());
        reponse.setContentType(MediaType.APPLICATION_JSON_VALUE);
        reponse.setCharacterEncoding("UTF-8");
        mapper.writeValue(reponse.getWriter(), new ErreurApi(
                code, message, null, FiltreCorrelation.courant(), OffsetDateTime.now(horloge)));
    }
}
